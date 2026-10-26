// The stand-in for gh that tests/issue-package.test.sh puts on the PATH: the labels and issues of GitHub's REST API as the
// package labels use them, kept in $GH_REST_STATE/github.json between calls, every call logged (calls.log, whole command line)
// and every write logged (writes.log). It answers what GitHub answers: label names are unique without regard to case, a
// duplicate is 422, an archived label cannot be put on an issue (422), taking a label off an issue that lacks it is 404, a
// list holds pageSize labels a page and --paginate follows every page, and an error prints its body on stdout and "gh: <message>
// (HTTP <status>)" on stderr with exit 1. Calls of two processes at once are served one after the other, so a race is
// the order of two calls and never a torn file.
//
// github.json: {pageSize, repos: {"owner/repo": {labels: [{name, color, description, archived_at, archived_by}],
//   issues: {"<number>": {title, state, state_reason, labels: [name]}}}},
//   omit: ["archived_at"], fail: [{match, skip, times, status, message, drop, then, page}], barriers: [{match, parties}]}
// omit leaves a field out of every label answer. A fail rule with `page` fails that page of a --paginate list.
// A fail rule matches "METHOD path" (match is a regular expression): after `skip` matches that pass it answers the `status` with
// `message`, `times` times; with `drop` the write is made and no answer comes (exit 1, "connection reset"); `then` is a change made
// by another hand right after the request: {removeIssueLabel: [repo, number, name]}. A barrier holds the first `parties`
// matching calls until all of them have arrived.
import fs from 'node:fs';
import path from 'node:path';

const dir = process.env.GH_REST_STATE ?? '';
const args = process.argv.slice(2);
const stateFile = path.join(dir, 'github.json');
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

fs.appendFileSync(path.join(dir, 'calls.log'), args.join(' ').replace(/\n/g, ' ') + '\n');

const lock = path.join(dir, 'lock');
const acquire = () => {
  for (let tries = 0; tries < 2000; tries++) {
    try {
      fs.closeSync(fs.openSync(lock, 'wx'));
      return;
    } catch {
      sleep(5);
    }
  }
  throw new Error('the stand-in could not take its lock');
};
const release = () => fs.rmSync(lock, { force: true });

const out = (text) => fs.writeSync(1, text);
const err = (text) => fs.writeSync(2, text);
const failure = (status, message, body) => {
  out(JSON.stringify(body ?? { message }) + '\n');
  err(`gh: ${message} (HTTP ${status})\n`);
  process.exitCode = 1;
};

let state;
const load = () => {
  state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
};
const save = () => {
  fs.writeFileSync(stateFile + '.tmp', JSON.stringify(state));
  fs.renameSync(stateFile + '.tmp', stateFile);
};

const lower = (text) => text.toLowerCase();
const repository = (full) => state.repos[Object.keys(state.repos).find((key) => lower(key) === lower(full)) ?? ''];
const labelWire = (label) => {
  const wire = { id: 1, name: label.name, color: label.color, default: false, description: label.description, archived_at: label.archived_at, archived_by: label.archived_by };
  if (state.omit?.includes('archived_at')) delete wire.archived_at;
  return wire;
};
const issueWire = (full, number, issue) => ({
  number: Number(number),
  title: issue.title,
  state: issue.state,
  state_reason: issue.state_reason,
  html_url: `https://github.com/${full}/issues/${number}`,
  labels: issue.labels.map((name) => labelWire(repository(full).labels.find((label) => label.name === name) ?? { name, color: 'ededed', description: '', archived_at: null, archived_by: null })),
});

const method = (() => {
  const at = args.findIndex((arg) => arg === '--method' || arg === '-X');
  return at < 0 ? (args.includes('--input') || args.includes('-f') || args.includes('-F') ? 'POST' : 'GET') : args[at + 1].toUpperCase();
})();

const body = {};
let input = null;
let pathAndQuery = '';
let paginate = false;
for (let index = 1; index < args.length; index++) {
  const arg = args[index];
  if (arg === '--method' || arg === '-X' || arg === '--jq' || arg === '-q' || arg === '-H') index++;
  else if (arg === '--paginate') paginate = true;
  else if (arg === '--input') {
    index++;
    input = JSON.parse(fs.readFileSync(0, 'utf8'));
  } else if (arg === '-f' || arg === '-F') {
    const [key, ...rest] = args[++index].split('=');
    const value = rest.join('=');
    body[key] = arg === '-F' && value === 'true' ? true : arg === '-F' && value === 'false' ? false : arg === '-F' && /^[0-9]+$/.test(value) ? Number(value) : value;
  } else if (!arg.startsWith('-') && pathAndQuery === '') pathAndQuery = arg;
}
const payload = input ?? body;

const run = () => {
  const [route, queryText = ''] = pathAndQuery.split('?');
  const query = Object.fromEntries(new URLSearchParams(queryText));
  const segments = route.split('/').map(decodeURIComponent);
  const write = method !== 'GET';
  const key = `${method} ${route}`;
  if (write) fs.appendFileSync(path.join(dir, 'writes.log'), `${key}\n`);

  let dropThis = false;
  let effectThis;
  for (const rule of state.fail) {
    if (rule.page !== undefined || !new RegExp(rule.match).test(key)) continue;
    if ((rule.skip ?? 0) > 0) {
      rule.skip--;
      continue;
    }
    if ((rule.times ?? 1) <= 0) continue;
    rule.times = (rule.times ?? 1) - 1;
    if (rule.status !== undefined) return failure(rule.status, rule.message);
    dropThis = rule.drop === true;
    effectThis = rule.then;
    break;
  }
  const finish = (value, status = 200) => {
    if (effectThis) {
      const [full, number, name] = effectThis.removeIssueLabel;
      const issue = repository(full).issues[number];
      issue.labels = issue.labels.filter((label) => lower(label) !== lower(name));
    }
    if (dropThis) {
      err('gh: Post "https://api.github.com": connection reset by peer\n');
      process.exitCode = 1;
      return;
    }
    if (value !== undefined) out(JSON.stringify(value) + '\n');
  };

  if (segments[0] === 'repos' && segments.length >= 3) {
    const full = `${segments[1]}/${segments[2]}`;
    const repo = repository(full);
    if (repo === undefined) return failure(404, 'Not Found');
    const rest = segments.slice(3);
    if (rest[0] === 'labels' && rest.length === 1) {
      if (method === 'GET') {
        const size = Math.min(Number(query.per_page ?? 30), state.pageSize);
        const wire = repo.labels.map(labelWire);
        const pages = [];
        for (let at = 0; at < Math.max(wire.length, 1); at += size) pages.push(wire.slice(at, at + size));
        const first = paginate ? 1 : Number(query.page ?? 1);
        const wanted = paginate ? pages : [pages[first - 1] ?? []];
        for (const [offset, page] of wanted.entries()) {
          const refusal = state.fail.find((rule) => rule.page === first + offset && new RegExp(rule.match).test(key));
          if (refusal) return failure(refusal.status, refusal.message);
          out(JSON.stringify(page) + '\n');
        }
        return finish(undefined);
      }
      if (method === 'POST') {
        if (typeof payload.name !== 'string' || payload.name === '') return failure(422, 'Validation Failed');
        if (repo.labels.some((label) => lower(label.name) === lower(payload.name))) {
          return failure(422, 'Validation Failed', { message: 'Validation Failed', errors: [{ resource: 'Label', code: 'already_exists', field: 'name' }] });
        }
        if ((payload.description ?? '').length > 100) return failure(422, 'Validation Failed');
        const label = { name: payload.name, color: payload.color ?? 'ededed', description: payload.description ?? '', archived_at: null, archived_by: null };
        repo.labels.push(label);
        return finish(labelWire(label), 201);
      }
    }
    if (rest[0] === 'labels' && rest.length === 2) {
      const label = repo.labels.find((candidate) => lower(candidate.name) === lower(rest[1]));
      if (label === undefined) return failure(404, 'Not Found');
      if (method === 'GET') return finish(labelWire(label));
      if (method === 'PATCH') {
        if (typeof payload.archived === 'boolean') {
          label.archived_at = payload.archived ? (label.archived_at ?? '2026-01-01T00:00:00Z') : null;
          label.archived_by = payload.archived ? { login: 'fake-user' } : null;
        } else if (payload.archived !== undefined) return failure(422, 'Validation Failed');
        if (typeof payload.description === 'string') label.description = payload.description;
        if (typeof payload.color === 'string') label.color = payload.color;
        return finish(labelWire(label));
      }
    }
    if (rest[0] === 'issues' && rest.length === 1 && method === 'GET') {
      const wanted = (query.labels ?? '').split(',').filter((name) => name !== '');
      const found = Object.entries(repo.issues)
        .filter(([, issue]) => (query.state === 'all' || (query.state ?? 'open') === issue.state) && wanted.every((name) => issue.labels.some((label) => lower(label) === lower(name))))
        .map(([number, issue]) => issueWire(full, number, issue));
      return finish(found);
    }
    if (rest[0] === 'issues' && rest.length >= 2) {
      const issue = repo.issues[rest[1]];
      if (issue === undefined) return failure(404, 'Not Found');
      if (rest.length === 2 && method === 'GET') return finish(issueWire(full, rest[1], issue));
      if (rest.length === 2 && method === 'PATCH') {
        if (payload.state === 'closed') {
          issue.state = 'closed';
          issue.state_reason = payload.state_reason ?? 'completed';
        } else if (payload.state === 'open') {
          issue.state = 'open';
          issue.state_reason = 'reopened';
        }
        return finish(issueWire(full, rest[1], issue));
      }
      if (rest[2] === 'labels' && rest.length === 3 && method === 'POST') {
        for (const name of payload.labels ?? []) {
          const label = repo.labels.find((candidate) => lower(candidate.name) === lower(name));
          if (label === undefined) return failure(422, 'Validation Failed');
          if (label.archived_at !== null && !issue.labels.some((carried) => lower(carried) === lower(name))) return failure(422, 'Validation Failed');
          if (!issue.labels.some((carried) => lower(carried) === lower(name))) issue.labels.push(label.name);
        }
        return finish(issue.labels.map((name) => labelWire(repo.labels.find((label) => label.name === name))));
      }
      if (rest[2] === 'labels' && rest.length === 4 && method === 'DELETE') {
        const at = issue.labels.findIndex((carried) => lower(carried) === lower(rest[3]));
        if (at < 0) return failure(404, 'Label does not exist');
        issue.labels.splice(at, 1);
        return finish(issue.labels.map((name) => labelWire(repo.labels.find((label) => label.name === name))));
      }
    }
  }
  return failure(404, `the stand-in has no ${key}`);
};

// the gh commands that the older scripts of the harness call: label create, label list, issue view and issue edit, repo view
const subcommand = () => {
  const flag = (name) => {
    const at = args.indexOf(name);
    return at < 0 ? undefined : args[at + 1];
  };
  const repo = repository(flag('--repo') ?? args[2] ?? '');
  if (args[0] === 'repo' && args[1] === 'view') {
    out('{"isPrivate":false}\n');
    return;
  }
  if (repo === undefined) return failure(404, 'Not Found');
  if (args[0] === 'label' && args[1] === 'create') {
    const name = args[2];
    const found = repo.labels.find((label) => lower(label.name) === lower(name));
    if (found !== undefined) {
      found.color = flag('--color') ?? found.color;
      found.description = flag('--description') ?? found.description;
    } else repo.labels.push({ name, color: flag('--color') ?? 'ededed', description: flag('--description') ?? '', archived_at: null, archived_by: null });
    fs.appendFileSync(path.join(dir, 'writes.log'), `label create ${name}\n`);
    return;
  }
  if (args[0] === 'label' && args[1] === 'list') {
    out(repo.labels.map((label) => label.name).join('\n') + '\n');
    return;
  }
  if (args[0] === 'issue' && args[1] === 'view') {
    out(repository(flag('--repo')).issues[args[2]].labels.join('\n') + '\n');
    return;
  }
  if (args[0] === 'issue' && args[1] === 'edit') {
    const issue = repo.issues[args[2]];
    for (let index = 3; index < args.length; index++) {
      if (args[index] === '--add-label' && !issue.labels.includes(args[index + 1])) issue.labels.push(args[index + 1]);
      if (args[index] === '--remove-label') issue.labels = issue.labels.filter((label) => label !== args[index + 1]);
    }
    fs.appendFileSync(path.join(dir, 'writes.log'), `issue edit ${args[2]}\n`);
    return;
  }
  failure(404, `the stand-in has no gh ${args.join(' ')}`);
};

acquire();
try {
  load();
  for (const [index, barrier] of (state.barriers ?? []).entries()) {
    const key = `${method} ${pathAndQuery.split('?')[0]}`;
    if (args[0] !== 'api' || !new RegExp(barrier.match).test(key)) continue;
    const arrivals = path.join(dir, `barrier-${index}`);
    fs.appendFileSync(arrivals, `${process.pid}\n`);
    const place = fs.readFileSync(arrivals, 'utf8').trim().split('\n').length;
    if (place > barrier.parties) continue;
    release();
    for (let waited = 0; fs.readFileSync(arrivals, 'utf8').trim().split('\n').length < barrier.parties && waited < 4000; waited++) sleep(5);
    acquire();
  }
  load();
  try {
    if (args[0] === 'api') run();
    else subcommand();
  } finally {
    save();
  }
} finally {
  release();
}
