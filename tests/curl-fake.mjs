// The stand-in for curl that tests/lib.sh puts on the PATH: Plane and Forgejo on this disk, so nothing in
// the suite reaches a network. It reads curl's arguments and the configuration on standard input as
// the harness sends them (url, request, header, data-binary), answers from $CURL_FAKE_STATE/*.json,
// writes what the service would write back, and logs every call:
//   requests.log  "<METHOD> <path+query>" and the body, one call per line pair
//   argv.log      the arguments of every call, env.log the environment of every call (so a test can
//                 look for a token in either)
// Plane answers where PLANE_URL is https://plane.example.test, Forgejo where FORGEJO_URL is
// https://forge.example.test or on the loopback address (tests/git-http-server.mjs serves its git over HTTP). Shapes follow Plane CE 1.4.2 (apps/api/plane at tag v1.4.2) and Forgejo 15.0
// (routers/api/v1, modules/structs), read for this suite; they are not a copy of either server.
//
//   node tests/curl-fake.mjs --init <state dir> [plane|forgejo]    write the first state
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const args = process.argv.slice(2);
if (args[0] === '--init') { init(args[1]); process.exit(0); }
const dir = process.env.CURL_FAKE_STATE;
const out = (f) => args[args.indexOf(f) + 1];
const read = (f, d) => { try { return JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')); } catch { return d; } };
const write = (f, v) => fs.writeFileSync(path.join(dir, f), JSON.stringify(v, null, 1));

function uuid(st) { st.counter = (st.counter || 100) + 1; return `00000000-0000-4000-8000-${String(st.counter).padStart(12, '0')}`; }

function init(d) {
  fs.mkdirSync(d, { recursive: true });
  const st = { counter: 100, clock: 1000, workspace: 'ws', token: 'plane-token-0123', users: [], projects: [] };
  const me = { id: uuid(st), email: 'me@example.test', display_name: 'me', first_name: 'Me', last_name: 'Tester' };
  st.users.push(me, { id: uuid(st), email: 'other@example.test', display_name: 'other', first_name: 'O', last_name: 'T' });
  const proj = { id: uuid(st), identifier: 'ENG', name: 'Engineering', states: [], labels: [], issues: [], comments: [], relations: [], activities: [] };
  for (const [name, group] of [['backlog', 'backlog'], ['ready', 'unstarted'], ['planned', 'unstarted'], ['implementing', 'started'],
                                ['review', 'started'], ['testing', 'started'], ['done', 'completed'], ['Cancelled', 'cancelled']]) {
    proj.states.push({ id: uuid(st), name, color: '#60646C', group, sequence: 15000 * (proj.states.length + 1), default: name === 'backlog' });
  }
  for (const name of ['type:feature', 'type:bug', 'area:tooling', 'repo:example-repo']) proj.labels.push({ id: uuid(st), name, color: '#aaaaaa', description: '' });
  st.projects.push(proj);
  const other = { id: uuid(st), identifier: 'OPS', name: 'Operations', states: [{ id: uuid(st), name: 'done', color: '#000', group: 'completed' }], labels: [{ id: uuid(st), name: 'repo:example-repo', color: '#000', description: '' }], issues: [], comments: [], relations: [], activities: [] };
  st.projects.push(other);
  fs.writeFileSync(path.join(d, 'plane.json'), JSON.stringify(st, null, 1));
  fs.writeFileSync(path.join(d, 'forgejo.json'), JSON.stringify({ token: 'forgejo-token-4567', user: { login: 'tester' }, repos: {}, statuses: {} }, null, 1));
}

// --- what curl was given -------------------------------------------------------------
let cfg = { header: [] };
if (args.includes('--config')) {
  // curl reads one option per line, the value quoted or not; a quote that is not closed on its line is part of the value
  for (const line of fs.readFileSync(0, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Za-z-]+)\s*[=:\s]\s*(.*?)\s*$/);
    if (!m) continue;
    const q = m[2].match(/^"(.*)"$/);
    const v = q ? q[1].replace(/\\(.)/g, '$1') : m[2];
    if (m[1] === 'header') cfg.header.push(v); else cfg[m[1]] = v;
  }
}
fs.appendFileSync(path.join(dir, 'argv.log'), args.join(' ') + '\n');
fs.appendFileSync(path.join(dir, 'env.log'), Object.entries(process.env).map(([k, v]) => `${k}=${v}`).join('\n') + '\n');
const method = cfg.request || 'GET';
const url = new URL(cfg.url || args.find((a) => /^https?:/.test(a)));
const body = cfg['data-binary'] ? (cfg['data-binary'].startsWith('@') ? fs.readFileSync(cfg['data-binary'].slice(1), 'utf8') : cfg['data-binary']) : '';
const q = url.searchParams;
fs.appendFileSync(path.join(dir, 'requests.log'), `${method} ${url.pathname}${url.search}\n${body}\n`);

function reply(status, value, headers = {}) {
  const head = `HTTP/2 ${status}\r\n` + Object.entries(headers).map(([k, v]) => `${k}: ${v}\r\n`).join('') + '\r\n';
  if (args.includes('--dump-header')) fs.writeFileSync(out('--dump-header'), head);
  if (args.includes('--output')) fs.writeFileSync(out('--output'), typeof value === 'string' ? value : JSON.stringify(value));
  process.stdout.write(String(status));
  process.exit(0);
}

// a planted answer: a file inject.json lists {match, status, body, headers, times}; the first entry whose
// match is in "<METHOD> <path+query>" answers, and one that ran out of times is dropped
const inject = read('inject.json', []);
const call = `${method} ${url.pathname}${url.search}`;
const hit = inject.findIndex((i) => call.includes(i.match));
if (hit >= 0) {
  const i = inject[hit];
  if (--i.times <= 0) inject.splice(hit, 1);
  write('inject.json', inject);
  reply(i.status, i.body ?? '', i.headers || {});
}

const json = (() => { try { return body ? JSON.parse(body) : {}; } catch { return null; } })();
const header = (n) => (cfg.header.find((h) => h.toLowerCase().startsWith(n.toLowerCase() + ':')) || '').replace(/^[^:]*:\s*/, '');
if (/^plane[0-9]*\.example\.test$/.test(url.hostname)) plane(); else if (url.hostname === 'forge.example.test' || url.hostname === '127.0.0.1') forgejo(); else reply(404, 'no such host');

// --- Plane ---------------------------------------------------------------------------------
function plane() {
  const st = read('plane.json');
  if (header('X-API-Key') !== st.token) reply(401, { detail: 'Authentication credentials were not provided.' });
  const p = url.pathname.replace(/^\/api\/v1\//, '').replace(/\/$/, '').split('/');
  const save = () => write('plane.json', st);
  const tick = () => new Date(Date.UTC(2026, 9, 18, 8, 0, ++st.clock)).toISOString();
  const page = (rows) => {
    const per = +(q.get('per_page') || 1000), at = +((q.get('cursor') || '').split(':')[1] || 0);
    const slice = rows.slice(at * per, (at + 1) * per);
    return { next_cursor: `${per}:${at + 1}:0`, next_page_results: rows.length > (at + 1) * per, count: slice.length, total_results: rows.length, results: slice };
  };
  if (p[0] === 'users' && p[1] === 'me') reply(200, st.users[0]);
  if (p[0] !== 'workspaces' || p[1] !== st.workspace) reply(404, { detail: 'Not found.' });
  if (p[2] === 'members') reply(200, st.users);
  if (p[2] === 'issues' && p.length === 4) {                  // by identifier: <IDENT>-<n>
    const [ident, n] = p[3].split('-');
    const pr = st.projects.find((x) => x.identifier === ident);
    const it = pr && pr.issues.find((i) => i.sequence_id === +n);
    if (!it) reply(404, { detail: 'Not found.' });
    reply(200, ser(st, pr, it));
  }
  if (p[2] !== 'projects') reply(404, { detail: 'Not found.' });
  if (p.length === 3) {
    if (method === 'GET') reply(200, page(st.projects.map(({ id, identifier, name }) => ({ id, identifier, name }))));
    if (st.projects.some((x) => x.identifier === json.identifier)) reply(409, { identifier: 'The project identifier is already taken' });
    const pr = { id: uuid(st), identifier: json.identifier, name: json.name, states: [], labels: [], issues: [], comments: [], relations: [], activities: [] };
    for (const [name, group] of [['Backlog', 'backlog'], ['Todo', 'unstarted'], ['In Progress', 'started'], ['Done', 'completed'], ['Cancelled', 'cancelled'], ['Triage', 'triage']]) {
      pr.states.push({ id: uuid(st), name, color: '#60646C', group, sequence: 15000 + 10000 * pr.states.length, default: name === 'Backlog' });   // DEFAULT_STATES of plane/db/models/state.py
    }
    st.projects.push(pr); save();
    reply(201, { id: pr.id, identifier: pr.identifier, name: pr.name });
  }
  const pr = st.projects.find((x) => x.id === p[3]);
  if (!pr) reply(404, { detail: 'Not found.' });
  const what = p[4];
  if (what === 'states') {
    if (p.length === 5) {
      if (method === 'GET') reply(200, page(pr.states.filter((s) => s.group !== 'triage').sort((a, b) => a.sequence - b.sequence)));
      if (pr.states.some((s) => s.name === json.name)) reply(409, { error: 'State with the same name already exists in the project' });
      const s = { id: uuid(st), name: json.name, color: json.color, group: json.group, sequence: pr.states.filter((x) => x.group !== 'triage').reduce((m, x) => Math.max(m, x.sequence), 0) + 15000, default: false };   // State.save: after the last, whatever is asked
      pr.states.push(s); save(); reply(200, s);
    }
    const s = pr.states.find((x) => x.id === p[5]);
    if (!s) reply(404, { detail: 'Not found.' });
    if (method === 'PATCH') { Object.assign(s, json); save(); }
    reply(200, s);
  }
  if (what === 'labels') {
    if (method === 'GET') reply(200, page(pr.labels));
    if (pr.labels.some((l) => l.name === json.name)) reply(409, { error: 'Label with the same name already exists in the project' });
    const l = { id: uuid(st), name: json.name, color: json.color, description: json.description || '' };
    pr.labels.push(l); save(); reply(201, l);
  }
  if (what !== 'issues' && what !== 'work-items') reply(404, { detail: 'Not found.' });
  if (p.length === 5) {
    if (method === 'GET') {
      const fields = q.get('fields') ? q.get('fields').split(',') : null;
      const rows = pr.issues.filter((i) => !i.archived_at).map((i) => ser(st, pr, i, fields));
      reply(200, page(rows));
    }
    if (!json.name) reply(400, { name: ['This field is required.'] });
    const it = { id: uuid(st), project: pr.id, name: json.name, description_html: json.description_html || '<p></p>', priority: 'none', parent: null, labels: [], assignees: [],
                 sort_order: 65535, external_source: json.external_source || null, external_id: json.external_id || null, archived_at: null, created_at: tick(), updated_at: tick(), completed_at: null };
    it.sequence_id = pr.issues.reduce((m, i) => Math.max(m, i.sequence_id), 0) + 1;
    const bad = write_issue(st, pr, it, json); if (bad) reply(400, bad);
    if (!it.state) it.state = (pr.states.find((s) => s.default) || pr.states[0]).id;
    pr.issues.push(it); save(); reply(201, ser(st, pr, it));
  }
  const it = pr.issues.find((i) => i.id === p[5]);
  if (!it) reply(404, { detail: 'Not found.' });
  const sub = p[6];
  if (!sub) {
    if (method === 'PATCH') {
      const was = it.state, bad = write_issue(st, pr, it, json); if (bad) reply(400, bad);
      if (it.state !== was) pr.activities.push({ id: uuid(st), issue: it.id, field: 'state', old_identifier: was, new_identifier: it.state, created_at: tick() });
      it.updated_at = tick(); save();
    }
    reply(200, ser(st, pr, it, null));
  }
  if (sub === 'comments') {
    if (method === 'GET') reply(200, page(pr.comments.filter((c) => c.issue === it.id).map((c) => ({ ...c, actor: q.get('expand') === 'actor' ? st.users[0] : c.actor }))));
    const c = { id: uuid(st), issue: it.id, comment_html: json.comment_html, created_at: tick(), actor: st.users[0].id, is_member: true };
    pr.comments.push(c); save(); reply(201, c);
  }
  if (sub === 'activities') reply(200, page(pr.activities.filter((a) => a.issue === it.id)));
  if (sub === 'relations' && what === 'work-items') {   // Plane 1.4 serves relations only under work-items/
    if (method === 'GET') {
      const mine = pr.relations.filter((r) => r.issue_id === it.id || r.related_issue_id === it.id);
      const ref = (id) => ({ project_id: pr.id, issue_id: id });
      reply(200, {
        blocking: mine.filter((r) => r.relation_type === 'blocked_by' && r.related_issue_id === it.id).map((r) => ref(r.issue_id)),
        blocked_by: mine.filter((r) => r.relation_type === 'blocked_by' && r.issue_id === it.id).map((r) => ref(r.related_issue_id)),
        duplicate: mine.filter((r) => r.relation_type === 'duplicate').map((r) => ref(r.issue_id === it.id ? r.related_issue_id : r.issue_id)),
        relates_to: [], start_after: [], start_before: [], finish_after: [], finish_before: [] });
    }
    for (const other of json.issues) pr.relations.push({ issue_id: it.id, related_issue_id: other, relation_type: json.relation_type });
    save(); reply(201, json.issues.map((o) => ({ id: o, relation_type: json.relation_type })));
  }
  reply(404, { detail: 'Not found.' });
}

// the serializer of IssueSerializer.create/update: ids, with a label of another project dropped without a word
function write_issue(st, pr, it, j) {
  if (j.name !== undefined) it.name = j.name;
  if (j.description_html !== undefined) it.description_html = j.description_html;
  if (j.sort_order !== undefined) it.sort_order = j.sort_order;
  if (j.priority !== undefined) { if (!['urgent', 'high', 'medium', 'low', 'none'].includes(j.priority)) return { priority: ['not a valid choice'] }; it.priority = j.priority; }
  if (j.state !== undefined) {
    const s = pr.states.find((x) => x.id === j.state);
    if (!s) return ['State is not valid please pass a valid state_id'];
    it.state = s.id; it.completed_at = s.group === 'completed' ? new Date().toISOString() : null;
  }
  if (j.parent !== undefined) { if (j.parent !== null && !pr.issues.some((i) => i.id === j.parent)) return ['Parent is not valid issue_id please pass a valid issue_id']; it.parent = j.parent; }
  if (j.labels !== undefined) it.labels = j.labels.filter((l) => pr.labels.some((x) => x.id === l));
  if (j.assignees !== undefined) it.assignees = j.assignees.filter((a) => st.users.some((u) => u.id === a));
  return null;
}

function ser(st, pr, it, fields = null) {
  const expand = (q.get('expand') || '').split(',');
  const o = { ...it };
  if (expand.includes('state')) o.state = pr.states.find((s) => s.id === it.state) && (({ id, name, color, group }) => ({ id, name, color, group }))(pr.states.find((s) => s.id === it.state));
  if (expand.includes('labels')) o.labels = it.labels.map((l) => pr.labels.find((x) => x.id === l)).filter(Boolean);
  if (expand.includes('assignees')) o.assignees = it.assignees.map((a) => st.users.find((u) => u.id === a));
  if (expand.includes('parent') && it.parent) { const par = pr.issues.find((i) => i.id === it.parent); o.parent = { id: par.id, sequence_id: par.sequence_id, project_id: pr.id }; }
  if (fields) for (const k of Object.keys(o)) if (!fields.includes(k)) delete o[k];
  return o;
}

// --- Forgejo -------------------------------------------------------------------------------
function forgejo() {
  const st = read('forgejo.json');
  if (header('Authorization') !== `token ${st.token}`) reply(401, { message: 'token is required' });
  const p = url.pathname.replace(/^\/api\/v1\//, '').split('/');
  const save = () => write('forgejo.json', st);
  if (p[0] === 'user' && p.length === 1) reply(200, st.user);
  if (p[0] === 'user' && p[1] === 'repos' || p[0] === 'orgs' && p[2] === 'repos') {
    const owner = p[0] === 'orgs' ? p[1] : st.user.login, full = `${owner}/${json.name}`;
    if (st.repos[full]) reply(409, { message: 'The repository with the same name already exists.' });
    st.repos[full] = { name: json.name, full_name: full, private: json.private, empty: true, default_branch: json.default_branch || 'main', files: [] };
    // as Forgejo does, the bare repository is made where the instance keeps them, when the test says where
    if (process.env.CURL_FAKE_REPO_ROOT) { fs.mkdirSync(path.join(process.env.CURL_FAKE_REPO_ROOT, owner), { recursive: true }); execFileSync('git', ['init', '-q', '--bare', '-b', 'main', path.join(process.env.CURL_FAKE_REPO_ROOT, `${full}.git`)]); }
    save(); reply(201, st.repos[full]);
  }
  if (p[0] !== 'repos') reply(404, { message: 'not found' });
  const repo = st.repos[`${p[1]}/${p[2]}`];
  if (!repo) reply(404, { message: 'The target couldn\'t be found.' });
  if (p.length === 3) reply(200, repo);
  if (p[3] === 'commits' && p[5] === 'status') {
    const s = st.statuses[p[4]];
    if (s === 'broken') reply(502, 'Bad Gateway');
    reply(200, s || {});
  }
  if (p[3] === 'git' && p[4] === 'trees') {
    const per = +(q.get('per_page') || 1000), at = +(q.get('page') || 1);
    if (repo.empty) reply(404, { message: 'sha not found' });
    reply(200, { sha: p[5], tree: repo.files.slice((at - 1) * per, at * per).map((f) => ({ path: f, type: 'blob', mode: '100644', size: 1, sha: 'a', url: '' })), truncated: repo.files.length > per, page: at, total_count: repo.files.length });
  }
  reply(404, { message: 'not found' });
}
