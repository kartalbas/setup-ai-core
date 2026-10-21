// The GitHub of tests/issue-transfer-plane.test.sh: node tests/carry-fixture.mjs <state dir> [scale] writes github.json for tests/gh-carry-fake.mjs.
// The small world has four repositories (one archived), five boards and the cases the owner's selection names; "scale" adds
// the project counted on 2026-10-20 to it: 4,100 issues, 624 of them archived cards, 18 open ones on no board, three boards.
import fs from 'node:fs';
const [dir, scale] = process.argv.slice(2);
const org = 'example-org', R = { repo: `${org}/example-repo`, tools: `${org}/tools`, web: `${org}/web`, old: `${org}/old` };
const url = (r, n) => `https://github.com/${r}/issues/${n}`;
const iss = (r, n, o = {}) => ({ number: n, id: `I_${r.split('/')[1]}${n}`, title: `${r.split('/')[1]} issue ${n}`, body: `body of ${n}\n`, state: 'OPEN', stateReason: null, url: url(r, n), labels: ['type:feature'], comments: [], parent: null, items: [], ...o });
const cm = (id, at, body, author = 'kadir') => ({ id, url: `https://github.com/x/issues/1#${id}`, createdAt: at, body, author });
const mem = (id, board, status, priority, isArchived = false) => ({ id, project: board, status, priority, isArchived });
const BODY = 'Fix the carry at lib/plane/tracker.sh:312\n\n```bash\nif [ "$a" -lt 2 ] && x=\'<y>\'; then echo "&lt; & >"; fi\n```\n\nlast line\n';
const issues = {
  [R.repo]: [
    iss(R.repo, 1, { body: BODY, labels: ['type:feature', 'area:gate'], items: [mem('PVTI_a1', 'PVT_A', 'ready', 'P1')],
      comments: [cm('IC_1a', '2026-10-01T10:00:00Z', 'first\n'), cm('IC_1b', '2026-10-01T10:00:00Z', 'same time, ```code``` & <b>', null), cm('IC_1c', '2026-10-02T10:00:00Z', 'write to someone@company.ch\n')] }),
    iss(R.repo, 2, { parent: { id: 'I_example-repo1', number: 1, url: url(R.repo, 1), repository: R.repo }, items: [mem('PVTI_a2', 'PVT_A', 'ready', 'P2')] }),
    iss(R.repo, 3, { state: 'CLOSED', stateReason: 'COMPLETED', items: [mem('PVTI_a3', 'PVT_A', 'Done', 'P2', true)] }),
    iss(R.repo, 4, { state: 'CLOSED', stateReason: 'NOT_PLANNED', items: [mem('PVTI_a4', 'PVT_A', 'Done', null, true)] }),
    iss(R.repo, 5, { state: 'CLOSED', stateReason: 'DUPLICATE' }),
    iss(R.repo, 6, { stateReason: 'REOPENED', items: [mem('PVTI_a6', 'PVT_A', 'Done', 'P3', true)] }),
    iss(R.repo, 7, { parent: { id: 'I_tools1', number: 1, url: url(R.tools, 1), repository: R.tools } }),
    iss(R.repo, 8, { items: [mem('PVTI_a8', 'PVT_A', 'backlog', 'P9')] }),
    iss(R.repo, 9, { items: [mem('PVTI_a9', 'PVT_A', 'ready', 'P2'), mem('PVTI_b9', 'PVT_B', 'planned', 'P2')] }),
    iss(R.repo, 10, { comments: Array.from({ length: 230 }, (_, k) => cm(`IC_10_${k}`, new Date(Date.parse('2026-10-03T00:00:00Z') + k * 1000).toISOString(), `comment ${k}`)) }),
    iss(R.repo, 11, { parent: { id: 'I_old1', number: 1, url: url(R.old, 1), repository: R.old } }),
    iss(R.repo, 12, { state: 'CLOSED', stateReason: 'NOT_PLANNED', comments: [cm('IC_12a', '2026-10-04T10:00:00Z', 'Moved to https://plane.example.test/ws/browse/ENG-9/')] }),
  ],
  [R.tools]: [iss(R.tools, 1, { items: [mem('PVTI_a20', 'PVT_A', 'ready', 'P0')] })],
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
const state = { page: { repositories: 3, issues: 4, nested: 100 }, repositories: Object.values(R).map((r) => ({ nameWithOwner: r, isArchived: r === R.old })), issues, boards,
  cards: { data: { node: { items: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } } }, fail: [] };
if (scale) {   // 4,100 issues in example-repo, tools and web: 624 archived cards, 18 open ones on no board, and every thread of the small world
  for (let n = 100; n < 4100 - 14 + 100; n++) {
    const r = n % 3 === 0 ? R.tools : n % 3 === 1 ? R.web : R.repo, k = n - 99, archived = k <= 621;
    const o = { number: n + 1000, comments: k % 400 === 0 ? Array.from({ length: 120 }, (_, j) => cm(`IC_s${n}_${j}`, '2026-10-05T00:00:00Z', `c${j}`)) : k % 7 === 0 ? [cm(`IC_s${n}`, '2026-10-05T00:00:00Z', 'one')] : [] };
    o.id = `I_s${n}`; o.url = url(r, o.number);
    if (archived) { o.state = 'CLOSED'; o.stateReason = 'COMPLETED'; o.items = [mem(`PVTI_s${n}`, 'PVT_A', 'Done', 'P2', true)]; }
    else if (k > 4086 - 15) { o.items = []; }
    else o.items = [mem(`PVTI_s${n}`, 'PVT_A', 'ready', 'P2')];
    issues[r].push(iss(r, o.number, o));
  }
}
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(`${dir}/github.json`, JSON.stringify(state));
