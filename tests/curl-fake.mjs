// The stand-in for curl that tests/lib.sh puts on the PATH: Forgejo on this disk, so nothing in
// the suite reaches a network. It reads curl's arguments and the configuration on standard input as
// the harness sends them (url, request, header, data-binary), answers from $CURL_FAKE_STATE/*.json,
// writes what the service would write back, and logs every call:
//   requests.log  "<METHOD> <path+query>" and the body, one call per line pair
//   argv.log      the arguments of every call, env.log the environment of every call (so a test can
//                 look for a token in either)
// Forgejo answers where FORGEJO_URL is https://forge.example.test or on the loopback address (tests/git-http-server.mjs
// serves its git over HTTP). Shapes follow Forgejo 15.0 (routers/api/v1, modules/structs), read for this suite; they are
// not a copy of the server.
//
//   node tests/curl-fake.mjs --init <state dir>    write the first state
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const args = process.argv.slice(2);
if (args[0] === '--init') { init(args[1]); process.exit(0); }
const dir = process.env.CURL_FAKE_STATE;
const out = (f) => args[args.indexOf(f) + 1];
const read = (f, d) => { try { return JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')); } catch { return d; } };
const write = (f, v) => fs.writeFileSync(path.join(dir, f), JSON.stringify(v, null, 1));

function init(d) {
  fs.mkdirSync(d, { recursive: true });
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
// CURL_FAKE_STDOUT names the file the command under test writes its standard output to: the size it has at each
// write is logged, so a test can tell what had been printed before the first write
if (method !== 'GET' && process.env.CURL_FAKE_STDOUT) fs.appendFileSync(path.join(dir, 'stdout-at-write.log'), `${method} ${url.pathname} ${fs.statSync(process.env.CURL_FAKE_STDOUT).size}\n`);

let lost = false;   // an injected {"status":0,"commit":true}: the call is carried out, and its answer never arrives
function reply(status, value, headers = {}) {
  if (lost) { process.stderr.write('curl: (28) Operation timed out\n'); process.exit(28); }
  const head = `HTTP/2 ${status}\r\n` + Object.entries(headers).map(([k, v]) => `${k}: ${v}\r\n`).join('') + '\r\n';
  if (args.includes('--dump-header')) fs.writeFileSync(out('--dump-header'), head);
  if (args.includes('--output')) fs.writeFileSync(out('--output'), typeof value === 'string' ? value : JSON.stringify(value));
  process.stdout.write(String(status));
  process.exit(0);
}

// ONE REQUEST AT A TIME: every call reads the state files, changes them and writes them back, so two curl
// processes at once would overwrite each other. A call takes the lock directory of the state, and gives it back
// when the process ends. CURL_FAKE_BARRIER names a folder: a POST whose path holds CURL_FAKE_BARRIER_MATCH waits,
// before it asks for the lock, until two such calls are in flight, so a test makes two commands meet at one
// write instead of hoping that they do.
if (method === 'POST' && process.env.CURL_FAKE_BARRIER && url.pathname.includes(process.env.CURL_FAKE_BARRIER_MATCH || '/')) {
  fs.mkdirSync(process.env.CURL_FAKE_BARRIER, { recursive: true });
  fs.writeFileSync(path.join(process.env.CURL_FAKE_BARRIER, `at.${process.pid}`), '');
  for (let i = 0; i < 400 && fs.readdirSync(process.env.CURL_FAKE_BARRIER).filter((f) => f.startsWith('at.')).length < 2; i++) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
}
const lockDir = path.join(dir, 'state.lock');
for (;;) {
  try { fs.mkdirSync(lockDir); break; } catch (e) { if (e.code !== 'EEXIST') throw e; Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5); }
}
process.on('exit', () => fs.rmSync(lockDir, { recursive: true, force: true }));

// a planted answer: a file inject.json lists {match, status, body, headers, times}; the first entry whose
// match is in "<METHOD> <path+query>" answers, and one that ran out of times is dropped
const inject = read('inject.json', []);
const call = `${method} ${url.pathname}${url.search}`;
const hit = inject.findIndex((i) => call.includes(i.match) && !((i.skip || 0) > 0 && (i.skip--, true)));   // skip: let that many matching calls through first
if (inject.length) write('inject.json', inject);
if (hit >= 0) {
  const i = inject[hit];
  if (--i.times <= 0) inject.splice(hit, 1);
  write('inject.json', inject);
  if (i.status === 0 && i.commit) lost = true;   // the write is made below, and its answer is dropped by reply()
  else if (i.status === 0) { process.stderr.write('curl: (28) Operation timed out\n'); process.exit(28); }   // no answer at all
  else reply(i.status, i.body ?? '', i.headers || {});
}

const json = (() => { try { return body ? JSON.parse(body) : {}; } catch { return null; } })();
const header = (n) => (cfg.header.find((h) => h.toLowerCase().startsWith(n.toLowerCase() + ':')) || '').replace(/^[^:]*:\s*/, '');
if (url.hostname === 'forge.example.test' || url.hostname === '127.0.0.1') forgejo(); else reply(404, 'no such host');

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
  // A branch resolves to the commit the repository stands at; a commit holds the files a test names in `commits`.
  if (p[3] === 'branches' && p.length === 5) {
    if (repo.empty || !repo.head_commit) reply(404, { message: 'branch does not exist' });
    reply(200, { name: p[4], commit: { id: repo.head_commit } });
  }
  if (p[3] === 'contents') {
    const files = (repo.commits || {})[q.get('ref')];
    const content = files && files[p.slice(4).join('/')];
    if (content === undefined) reply(404, { message: 'object does not exist' });
    reply(200, { type: 'file', encoding: 'base64', size: Buffer.byteLength(content), content: Buffer.from(content).toString('base64').replace(/(.{76})/g, '$1\n') });
  }
  if (p[3] === 'git' && p[4] === 'trees') {
    const per = +(q.get('per_page') || 1000), at = +(q.get('page') || 1);
    if (repo.empty) reply(404, { message: 'sha not found' });
    // HEAD is resolved by each request, to the tree the default branch holds then; a tree is also asked for by its own sha.
    // A test that moves the branch between two pages names the tree it moves to in head_after_next.
    const trees = repo.trees || { tree0: repo.files };
    const sha = p[5] === 'HEAD' ? (repo.head || 'tree0') : p[5];
    const files = trees[sha];
    if (!files) reply(404, { message: 'sha not found' });
    if (p[5] === 'HEAD' && repo.head_after_next) { repo.head = repo.head_after_next; delete repo.head_after_next; save(); }
    reply(200, { sha, tree: files.slice((at - 1) * per, at * per).map((f) => ({ path: f, type: 'blob', mode: '100644', size: 1, sha: 'a', url: '' })), truncated: files.length > per, page: at, total_count: files.length });
  }
  reply(404, { message: 'not found' });
}
