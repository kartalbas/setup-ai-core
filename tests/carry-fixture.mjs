// The GitHub of tests/issue-transfer-plane.test.sh: node tests/carry-fixture.mjs <state dir> [bulk | scale] writes github.json
// for tests/gh-carry-fake.mjs. The small world has four repositories (one archived), five boards and the cases the owner's
// selection names. The account that runs the carry is `tester`: it is assigned to the first two issues of example-repo (spelled TESTER
// on the second, beside anton, who is not it) and to the first of tools; anton alone is assigned to the third of example-repo. "pair" is two issues of it, a sub-issue and its parent in another destination, and no board. "bulk" adds the answers larger than one command-line argument (128 KiB on Linux): a board of 1,500 more
// cards, an issue of 200 comments of 1,500 characters and one comment of 27,000 ampersands, 135,000 characters once escaped.
// "scale" is the project counted on 2026-10-20: 4,100 issues, 624 of them archived cards, 18 open ones on no board, three
// boards, and the first board holds a card for every issue that has one.
import fs from 'node:fs';
const [dir, mode] = process.argv.slice(2);
const scale = mode === 'scale', bulk = mode === 'bulk', pair = mode === 'pair';
const LOGIN = 'tester', org = 'example-org', R = { repo: `${org}/example-repo`, tools: `${org}/tools`, web: `${org}/web`, old: `${org}/old` };
const url = (r, n) => `https://github.com/${r}/issues/${n}`;
const iss = (r, n, o = {}) => ({ number: n, id: `I_${r.split('/')[1]}${n}`, title: `${r.split('/')[1]} issue ${n}`, body: `body of ${n}\n`, state: 'OPEN', stateReason: null, url: url(r, n), labels: ['type:feature'], assignees: [], comments: [], parent: null, items: [], ...o });
const cm = (id, at, body, author = 'kadir', authorAssociation = 'MEMBER') => ({ id, url: `https://github.com/x/issues/1#${id}`, createdAt: at, body, author, authorAssociation });
const mem = (id, board, status, priority, isArchived = false) => ({ id, project: board, status, priority, isArchived });
const event = (type, createdAt) => ({ type, createdAt });
const nodeId = (prefix, n) => `${prefix}_kwDOBqBU3c4AbCdEzgJk${n}`;   // as long as the node ids GitHub hands out
const BODY = 'Fix the carry at lib/plane/tracker.sh:312\n\n```bash\nif [ "$a" -lt 2 ] && x=\'<y>\'; then echo "&lt; & >"; fi\n```\n\nlast line\n';
const issues = {
  [R.repo]: [
    iss(R.repo, 1, { body: BODY, labels: ['type:feature', 'area:gate'], assignees: [LOGIN], items: [mem('PVTI_a1', 'PVT_A', 'ready', 'P1')],
      comments: [cm('IC_1a', '2026-10-01T10:00:00Z', 'first\n'), cm('IC_1b', '2026-10-01T10:00:00Z', 'same time, ```code``` & <b>', null), cm('IC_1c', '2026-10-02T10:00:00Z', 'write to someone@company.ch\n')] }),
    iss(R.repo, 2, { assignees: [LOGIN.toUpperCase(), 'anton'], parent: { id: 'I_example-repo1', number: 1, url: url(R.repo, 1), repository: R.repo }, items: [mem('PVTI_a2', 'PVT_A', 'ready', 'P2')] }),
    iss(R.repo, 3, { state: 'CLOSED', stateReason: 'COMPLETED', assignees: ['anton'], items: [mem('PVTI_a3', 'PVT_A', 'Done', 'P2', true)] }),
    iss(R.repo, 4, { state: 'CLOSED', stateReason: 'NOT_PLANNED', items: [mem('PVTI_a4', 'PVT_A', 'Done', null, true)] }),
    iss(R.repo, 5, { state: 'CLOSED', stateReason: 'DUPLICATE' }),
    iss(R.repo, 6, { stateReason: 'REOPENED', items: [mem('PVTI_a6', 'PVT_A', 'Done', 'P3', true)], timeline: [event('CLOSED_EVENT', '2026-10-05T08:00:00Z'), event('REOPENED_EVENT', '2026-10-05T09:00:00Z')] }),
    iss(R.repo, 7, { parent: { id: 'I_tools1', number: 1, url: url(R.tools, 1), repository: R.tools } }),
    iss(R.repo, 8, { items: [mem('PVTI_a8', 'PVT_A', 'backlog', 'P9')] }),
    iss(R.repo, 9, { items: [mem('PVTI_a9', 'PVT_A', 'ready', 'P2'), mem('PVTI_b9', 'PVT_B', 'planned', 'P2')] }),
    iss(R.repo, 10, { comments: Array.from({ length: 230 }, (_, k) => cm(`IC_10_${k}`, new Date(Date.parse('2026-10-03T00:00:00Z') + k * 1000).toISOString(), `comment ${k}`)) }),
    iss(R.repo, 11, { parent: { id: 'I_old1', number: 1, url: url(R.old, 1), repository: R.old } }),
    iss(R.repo, 12, { state: 'CLOSED', stateReason: 'NOT_PLANNED', comments: [cm('IC_12a', '2026-10-04T10:00:00Z', 'Moved to https://plane.example.test/ws/browse/ENG-9/')], timeline: [event('CLOSED_EVENT', '2026-10-04T10:00:05Z')] }),
  ],
  [R.tools]: [iss(R.tools, 1, { assignees: [LOGIN], items: [mem('PVTI_a20', 'PVT_A', 'ready', 'P0')] })],
  [R.web]: [iss(R.web, 1, { items: [mem('PVTI_c1', 'PVT_C', 'ready', null)] })],
  [R.old]: [iss(R.old, 1)],
};
const ref = (r, n) => ({ id: `I_${r.split('/')[1]}${n}`, number: n, repository: r });
const board = (id, number, title, closed, repos, items) => ({ id, number, title, url: `https://github.com/orgs/${org}/projects/${number}`, closed, readme: `readme of ${title}`, repositories: repos.map((r) => ({ nameWithOwner: r, isArchived: r === R.old })), items });
const item = (m, r, n) => ({ id: m.id, isArchived: m.isArchived, issue: ref(r, n), status: m.status, priority: m.priority });
const boards = [
  board('PVT_A', 1, 'Main', false, [R.repo, R.tools], [[1, 1], [2, 2], [3, 3], [4, 4], [6, 6], [8, 8], [9, 9]].map(([k, n]) => item(issues[R.repo][n - 1].items.find((m) => m.project === 'PVT_A'), R.repo, n)).concat([item(issues[R.tools][0].items[0], R.tools, 1)])),
  board('PVT_B', 2, 'Second', false, [R.repo], [item(issues[R.repo][8].items[1], R.repo, 9)]),
  board('PVT_C', 3, 'Web', false, [R.web], [item(issues[R.web][0].items[0], R.web, 1)]),
  board('PVT_D', 4, 'Empty and unlinked', false, [], []),
  board('PVT_E', 5, 'Closed, linked to an archived repository only', true, [R.old], []),
];
const state = { login: LOGIN, page: { repositories: 3, issues: 4, nested: 100 }, repositories: Object.values(R).map((r) => ({ nameWithOwner: r, isArchived: r === R.old })), issues, boards,
  cards: { data: { node: { items: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } } }, fail: [] };
if (bulk || scale) {   // answers larger than one command-line argument
  const filler = (k) => `${k}: ` + 'The carry keeps this sentence to the byte, "quoted" and \\ escaped. '.repeat(23);
  issues[R.repo].push(iss(R.repo, 13, { comments: Array.from({ length: 200 }, (_, k) => cm(`IC_13_${k}`, new Date(Date.parse('2026-10-06T00:00:00Z') + k * 1000).toISOString(), filler(k))) }));
}
if (bulk) {
  issues[R.repo].push(iss(R.repo, 14, { comments: [cm('IC_14a', '2026-10-07T10:00:00Z', '&'.repeat(27000))] }));
  for (let n = 2001; n <= 3500; n++) {   // cards of issues that stand in no repository of the selection
    boards[0].items.push({ id: nodeId('PVTI', n), isArchived: n % 4 === 0, issue: { id: nodeId('I', n), number: n, repository: R.tools }, status: n % 4 === 0 ? 'Done' : 'ready', priority: 'P2' });
  }
}
if (scale) {   // 4,100 issues in example-repo, tools and web: 624 archived cards, 18 open ones on no board, a card on the first board for each
  for (let n = 100; n < 4100 - 15 + 100; n++) {
    const r = n % 3 === 0 ? R.tools : n % 3 === 1 ? R.web : R.repo, k = n - 99, archived = k <= 621;
    const o = { number: n + 1000, comments: k % 400 === 0 ? Array.from({ length: 120 }, (_, j) => cm(`IC_s${n}_${j}`, '2026-10-05T00:00:00Z', `c${j}`)) : k % 7 === 0 ? [cm(`IC_s${n}`, '2026-10-05T00:00:00Z', 'one')] : [] };
    o.id = nodeId('I', n); o.url = url(r, o.number);
    if (archived) { o.state = 'CLOSED'; o.stateReason = 'COMPLETED'; o.items = [mem(nodeId('PVTI', n), 'PVT_A', 'Done', 'P2', true)]; }
    else if (k > 4085 - 14) { o.items = []; }
    else o.items = [mem(nodeId('PVTI', n), 'PVT_A', 'ready', 'P2')];
    issues[r].push(iss(r, o.number, o));
    for (const m of o.items) boards[0].items.push({ id: m.id, isArchived: m.isArchived, issue: { id: o.id, number: o.number, repository: r }, status: m.status, priority: m.priority });
  }
}
if (pair) {
  state.repositories = state.repositories.filter((r) => [R.repo, R.tools].includes(r.nameWithOwner));
  state.issues = { [R.repo]: [issues[R.repo][6]], [R.tools]: issues[R.tools] };
  state.boards = [];
}
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(`${dir}/github.json`, JSON.stringify(state));
