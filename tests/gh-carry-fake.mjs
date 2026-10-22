// The stand-in for gh that tests/issue-transfer-plane.test.sh puts on the PATH: GitHub's GraphQL as the issue carry
// reads it, answered from $GH_CARRY_STATE/github.json. It logs every call (calls.log, the whole command line), so a test
// can assert that nothing but reads was asked, and it refuses a call it does not know. It answers only what GitHub
// would answer for the query as it is spelled: an issue query without `stateReason(enableDuplicate: true)` gets
// NOT_PLANNED for a duplicate, `projectItems` without `includeArchived: true` and a board's `items` without
// `archivedStates:[ARCHIVED, NOT_ARCHIVED]` leave the archived cards out, `timelineItems` returns the event types its
// `itemTypes` names, and a connection is paged by `first`. The whole answer is written before the process ends: a pipe
// takes 64 KiB at a time, and an answer cut there would be read as a shorter listing.
//
// `gh api user` answers {login} from github.json, the account that runs the carry.
//
// github.json: {login, page: {repositories, issues, nested}, repositories: [{nameWithOwner, isArchived}],
//   issues: {"owner/repo": [{number, id, title, body, state, stateReason, url, labels: [name], assignees: [login], comments: [{id, url,
//   createdAt, body, author, authorAssociation}], parent: {id, number, url, repository}, items: [{id, isArchived, project, status, priority}],
//   timeline: [{type: "CLOSED_EVENT" | "REOPENED_EVENT", createdAt}]}]},
//   boards: [{id, number, title, url, closed, readme, repositories: [{nameWithOwner, isArchived}], items: [{id, isArchived,
//   issue: {id, number, repository}, status, priority}]}], cards: <the answer of the board query of board_cards_of_repo>,
//   fail: [{match, times, errors}]}
import fs from 'node:fs';
import path from 'node:path';

const dir = process.env.GH_CARRY_STATE;
const args = process.argv.slice(2);
fs.appendFileSync(path.join(dir, 'calls.log'), args.join(' ').replace(/\n/g, ' ') + '\n');
const st = JSON.parse(fs.readFileSync(path.join(dir, 'github.json'), 'utf8'));
const v = {}; let query = '';
for (let i = 2; i < args.length; i++) {
  if (args[i] === '-f' || args[i] === '-F') { const [k, ...rest] = args[++i].split('='); const val = rest.join('='); if (k === 'query') query = val; else v[k] = args[i - 1] === '-F' && /^\d+$/.test(val) ? +val : val; }
}
const data = (d) => ({ out: JSON.stringify({ data: d }) + '\n', code: 0 });
const page = (rows, first, after, cap) => {
  const n = Math.min(first, cap || first), at = after ? +after.slice(1) : 0, end = Math.min(at + n, rows.length);
  return { nodes: rows.slice(at, end), pageInfo: { hasNextPage: end < rows.length, endCursor: end < rows.length ? `c${end}` : null } };
};
const first = (re) => +((query.match(re) || [])[1] || 100);

const duplicate = query.includes('stateReason(enableDuplicate: true)');
const reason = (i) => (i.state === 'CLOSED' ? (i.stateReason === 'DUPLICATE' && !duplicate ? 'NOT_PLANNED' : i.stateReason) : (i.stateReason || null));
const fieldValues = (i) => ({ nodes: [...(i.status ? [{ name: i.status, field: { name: 'Status' } }] : []), ...(i.priority ? [{ name: i.priority, field: { name: 'Priority' } }] : []), {}] });
const items = (i, after) => {
  const rows = (i.items || []).filter((m) => query.includes('includeArchived: true') || !m.isArchived).map((m) => ({ id: m.id, isArchived: m.isArchived, project: { id: m.project }, fieldValues: fieldValues(m) }));
  return page(rows, 50, after, st.page.nested);
};
const itemTypes = ((query.match(/itemTypes:\s*\[([A-Z_,\s]*)\]/) || [])[1] || '').split(',').map((t) => t.trim());
const timeline = (i, after) => page((i.timeline || []).filter((e) => itemTypes.includes(e.type)).map((e) => ({
  ...(query.includes('__typename') ? { __typename: e.type === 'CLOSED_EVENT' ? 'ClosedEvent' : 'ReopenedEvent' } : {}), createdAt: e.createdAt })), 100, after, st.page.nested);
const issueNode = (repo, i) => ({
  id: i.id, number: i.number, title: i.title, body: i.body, state: i.state, stateReason: reason(i), url: i.url,
  labels: ((p) => ({ nodes: p.nodes.map((name) => ({ name })), pageInfo: p.pageInfo }))(page(i.labels, 100, null, st.page.nested)),
  ...(query.includes('assignees(first:') ? { assignees: { nodes: (i.assignees || []).slice(0, first(/assignees\(first:(\d+)/)).map((login) => ({ login })) } } : {}),
  comments: page(i.comments.map((c) => ({ ...c, author: c.author ? { login: c.author } : null })), 100, null, st.page.nested),
  parent: i.parent ? { id: i.parent.id, number: i.parent.number, url: i.parent.url, repository: { nameWithOwner: i.parent.repository } } : null,
  projectItems: items(i, null),
  timelineItems: timeline(i, null),
});
const cardNodes = (board) => board.items.filter((m) => query.includes('archivedStates:[ARCHIVED, NOT_ARCHIVED]') || !m.isArchived)
  .map((m) => ({ id: m.id, isArchived: m.isArchived, content: m.issue ? { id: m.issue.id, number: m.issue.number, repository: { nameWithOwner: m.issue.repository } } : {}, fieldValues: fieldValues(m) }));

const respond = () => {
  if (args[0] === 'api' && args[1] === 'user') return { out: JSON.stringify({ login: st.login }) + '\n', code: 0 };
  if (args[0] !== 'api' || args[1] !== 'graphql') return { err: `unexpected gh call: ${args.join(' ')}\n`, code: 1 };
  if (st.fail) {
    const hit = st.fail.findIndex((f) => query.includes(f.match) || args.join(' ').includes(f.match));
    if (hit >= 0) {
      const f = st.fail[hit]; if (--f.times <= 0) st.fail.splice(hit, 1);
      fs.writeFileSync(path.join(dir, 'github.json'), JSON.stringify(st));
      if (f.rate) return { err: 'gh: API rate limit exceeded\n', code: 1 };
      return { out: JSON.stringify({ errors: f.errors || [{ message: 'partial failure' }], data: null }) + '\n', code: 0 };
    }
  }
  if (query.includes('rateLimit')) return data({ rateLimit: { remaining: 100, resetAt: '2026-10-21T10:00:00Z' } });

  if (query.includes('organization(login:$o){ repositories(')) {
    const p = page(st.repositories, 100, v.c, st.page.repositories);
    // the count of issues and whether they are enabled are answered where the query asks for them
    if (query.includes('hasIssuesEnabled') && query.includes('issues{ totalCount }')) {
      p.nodes = p.nodes.map((r) => ({ ...r, hasIssuesEnabled: r.hasIssuesEnabled !== false, issues: { totalCount: (st.issues[r.nameWithOwner] || []).length } }));
    }
    return data({ organization: { repositories: p } });
  }
  if (query.includes('repository(owner:$o,name:$n){ issues(')) {
    const rows = (st.issues[`${v.o}/${v.n}`] || []);
    const p = page(rows, first(/issues\(first:(\d+)/), v.c, st.page.issues);
    return data({ repository: { issues: { nodes: p.nodes.map((i) => issueNode(`${v.o}/${v.n}`, i)), pageInfo: p.pageInfo } } });
  }
  if (query.includes('repository(owner:$o,name:$n){ issue(number:$i)')) {
    const i = (st.issues[`${v.o}/${v.n}`] || []).find((x) => x.number === v.i);
    return data({ repository: { issue: i ? issueNode(`${v.o}/${v.n}`, i) : null } });
  }
  if (query.includes('organization(login:$o){ projectsV2(')) {
    const rows = st.boards.map((b) => ({
      id: b.id, number: b.number, title: b.title, url: b.url, closed: b.closed, readme: b.readme,
      repositories: page(b.repositories, 100, null, st.page.nested),
      items: page(cardNodes(b), 100, null, st.page.nested),
    }));
    return data({ organization: { projectsV2: page(rows, 20, v.c, 20) } });
  }
  if (query.includes('node(id:$id)')) {
    const board = st.boards.find((b) => b.id === v.id);
    if (board && query.includes('repositories(first:100')) return data({ node: { repositories: page(board.repositories, 100, v.c, st.page.nested) } });
    if (board && query.includes('items(first:100')) return data({ node: { items: page(cardNodes(board), 100, v.c, st.page.nested) } });
    const found = Object.values(st.issues).flat().find((i) => i.id === v.id);
    if (found) {
      if (query.includes('labels(first:100')) { const p = page(found.labels, 100, v.c, st.page.nested); return data({ node: { labels: { nodes: p.nodes.map((name) => ({ name })), pageInfo: p.pageInfo } } }); }
      if (query.includes('comments(first:100')) return data({ node: { comments: page(found.comments.map((c) => ({ ...c, author: c.author ? { login: c.author } : null })), 100, v.c, st.page.nested) } });
      if (query.includes('projectItems(first:100')) return data({ node: { projectItems: items(found, v.c) } });
      if (query.includes('timelineItems(first:100')) return data({ node: { timelineItems: timeline(found, v.c) } });
    }
    return data({ node: null });
  }
  if (query.includes('items(first:100')) return { out: JSON.stringify(st.cards) + '\n', code: 0 };   // board_cards_of_repo
  return { err: `unexpected gh call: ${args.join(' ')}\n`, code: 1 };
};

const answer = respond();
if (answer.err) process.stderr.write(answer.err);
if (answer.out) process.stdout.write(answer.out);
process.exitCode = answer.code;   // the process ends when stdout is drained, never before
