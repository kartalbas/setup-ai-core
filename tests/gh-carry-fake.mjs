// The stand-in for gh that tests/issue-transfer-plane.test.sh puts on the PATH: GitHub's GraphQL as the issue carry
// reads it, answered from $GH_CARRY_STATE/github.json. It logs every call (calls.log, the whole command line), so a test
// can assert that nothing but reads was asked, and it refuses a call it does not know. It answers only what GitHub
// would answer for the query as it is spelled: an issue query without `stateReason(enableDuplicate: true)` gets
// NOT_PLANNED for a duplicate, `projectItems` without `includeArchived: true` and a board's `items` without
// `archivedStates:[ARCHIVED, NOT_ARCHIVED]` leave the archived cards out, and a connection is paged by `first`.
//
// github.json: {page: {repositories, issues, nested}, repositories: [{nameWithOwner, isArchived}],
//   issues: {"owner/repo": [{number, id, title, body, state, stateReason, url, labels: [name], comments: [{id, url,
//   createdAt, body, author}], parent: {id, number, url, repository}, items: [{id, isArchived, project, status, priority}]}]},
//   boards: [{id, number, title, url, closed, readme, repositories: [{nameWithOwner, isArchived}], items: [{id, isArchived,
//   issue: {id, number, repository}, status, priority}]}], cards: <the answer of the board query of board_cards_of_repo>,
//   fail: [{match, times, errors}]}
import fs from 'node:fs';
import path from 'node:path';

const dir = process.env.GH_CARRY_STATE;
const args = process.argv.slice(2);
fs.appendFileSync(path.join(dir, 'calls.log'), args.join(' ').replace(/\n/g, ' ') + '\n');
const st = JSON.parse(fs.readFileSync(path.join(dir, 'github.json'), 'utf8'));
if (args[0] !== 'api' || args[1] !== 'graphql') { process.stderr.write(`unexpected gh call: ${args.join(' ')}\n`); process.exit(1); }
const v = {}; let query = '';
for (let i = 2; i < args.length; i++) {
  if (args[i] === '-f' || args[i] === '-F') { const [k, ...rest] = args[++i].split('='); const val = rest.join('='); if (k === 'query') query = val; else v[k] = args[i - 1] === '-F' && /^\d+$/.test(val) ? +val : val; }
}
const out = (data) => { process.stdout.write(JSON.stringify({ data }) + '\n'); process.exit(0); };
const page = (rows, first, after, cap) => {
  const n = Math.min(first, cap || first), at = after ? +after.slice(1) : 0, end = Math.min(at + n, rows.length);
  return { nodes: rows.slice(at, end), pageInfo: { hasNextPage: end < rows.length, endCursor: end < rows.length ? `c${end}` : null } };
};
const first = (re) => +((query.match(re) || [])[1] || 100);

if (st.fail) {
  const hit = st.fail.findIndex((f) => query.includes(f.match) || args.join(' ').includes(f.match));
  if (hit >= 0) {
    const f = st.fail[hit]; if (--f.times <= 0) st.fail.splice(hit, 1);
    fs.writeFileSync(path.join(dir, 'github.json'), JSON.stringify(st));
    if (f.rate) { process.stderr.write('gh: API rate limit exceeded\n'); process.exit(1); }
    process.stdout.write(JSON.stringify({ errors: f.errors || [{ message: 'partial failure' }], data: null }) + '\n'); process.exit(0);
  }
}
if (query.includes('rateLimit')) out({ rateLimit: { remaining: 100, resetAt: '2026-10-21T10:00:00Z' } });

const duplicate = query.includes('stateReason(enableDuplicate: true)');
const reason = (i) => (i.state === 'CLOSED' ? (i.stateReason === 'DUPLICATE' && !duplicate ? 'NOT_PLANNED' : i.stateReason) : (i.stateReason || null));
const fieldValues = (i) => ({ nodes: [...(i.status ? [{ name: i.status, field: { name: 'Status' } }] : []), ...(i.priority ? [{ name: i.priority, field: { name: 'Priority' } }] : []), {}] });
const items = (i, after) => {
  const rows = (i.items || []).filter((m) => query.includes('includeArchived: true') || !m.isArchived).map((m) => ({ id: m.id, isArchived: m.isArchived, project: { id: m.project }, fieldValues: fieldValues(m) }));
  return page(rows, 50, after, st.page.nested);
};
const issueNode = (repo, i) => ({
  id: i.id, number: i.number, title: i.title, body: i.body, state: i.state, stateReason: reason(i), url: i.url,
  labels: ((p) => ({ nodes: p.nodes.map((name) => ({ name })), pageInfo: p.pageInfo }))(page(i.labels, 100, null, st.page.nested)),
  comments: page(i.comments.map((c) => ({ ...c, author: c.author ? { login: c.author } : null })), 100, null, st.page.nested),
  parent: i.parent ? { id: i.parent.id, number: i.parent.number, url: i.parent.url, repository: { nameWithOwner: i.parent.repository } } : null,
  projectItems: items(i, null),
});

if (query.includes('organization(login:$o){ repositories(')) out({ organization: { repositories: page(st.repositories, 100, v.c, st.page.repositories) } });
if (query.includes('repository(owner:$o,name:$n){ issues(')) {
  const rows = (st.issues[`${v.o}/${v.n}`] || []);
  const p = page(rows, first(/issues\(first:(\d+)/), v.c, st.page.issues);
  out({ repository: { issues: { nodes: p.nodes.map((i) => issueNode(`${v.o}/${v.n}`, i)), pageInfo: p.pageInfo } } });
}
if (query.includes('repository(owner:$o,name:$n){ issue(number:$i)')) {
  const i = (st.issues[`${v.o}/${v.n}`] || []).find((x) => x.number === v.i);
  out({ repository: { issue: i ? issueNode(`${v.o}/${v.n}`, i) : null } });
}
if (query.includes('organization(login:$o){ projectsV2(')) {
  const archivedAsked = query.includes('archivedStates:[ARCHIVED, NOT_ARCHIVED]');
  const rows = st.boards.map((b) => ({
    id: b.id, number: b.number, title: b.title, url: b.url, closed: b.closed, readme: b.readme,
    repositories: page(b.repositories, 100, null, st.page.nested),
    items: page(b.items.filter((m) => archivedAsked || !m.isArchived).map((m) => ({ id: m.id, isArchived: m.isArchived, content: m.issue ? { id: m.issue.id, number: m.issue.number, repository: { nameWithOwner: m.issue.repository } } : {}, fieldValues: fieldValues(m) })), 100, null, st.page.nested),
  }));
  out({ organization: { projectsV2: page(rows, 20, v.c, 20) } });
}
if (query.includes('node(id:$id)')) {
  const archivedAsked = query.includes('archivedStates:[ARCHIVED, NOT_ARCHIVED]');
  const board = st.boards.find((b) => b.id === v.id);
  if (board && query.includes('repositories(first:100')) out({ node: { repositories: page(board.repositories, 100, v.c, st.page.nested) } });
  if (board && query.includes('items(first:100')) out({ node: { items: page(board.items.filter((m) => archivedAsked || !m.isArchived).map((m) => ({ id: m.id, isArchived: m.isArchived, content: m.issue ? { id: m.issue.id, number: m.issue.number, repository: { nameWithOwner: m.issue.repository } } : {}, fieldValues: fieldValues(m) })), 100, v.c, st.page.nested) } });
  const found = Object.entries(st.issues).flatMap(([repo, rows]) => rows.map((i) => [repo, i])).find(([, i]) => i.id === v.id);
  if (found) {
    const [repo, i] = found;
    if (query.includes('labels(first:100')) { const p = page(i.labels, 100, v.c, st.page.nested); out({ node: { labels: { nodes: p.nodes.map((name) => ({ name })), pageInfo: p.pageInfo } } }); }
    if (query.includes('comments(first:100')) out({ node: { comments: page(i.comments.map((c) => ({ ...c, author: c.author ? { login: c.author } : null })), 100, v.c, st.page.nested) } });
    if (query.includes('projectItems(first:100')) out({ node: { projectItems: items(i, v.c) } });
  }
  out({ node: null });
}
if (query.includes('items(first:100')) { process.stdout.write(JSON.stringify(st.cards) + '\n'); process.exit(0); }   // board_cards_of_repo
process.stderr.write(`unexpected gh call: ${args.join(' ')}\n`); process.exit(1);
