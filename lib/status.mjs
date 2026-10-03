// The state of the work on one board and the plan for the rest, counted, never written by a model.
// bin/status.sh and bin/status.ps1 read the board and start this, so the two spellings print the
// same plan by construction.
//
//   node lib/status.mjs --items-file F --columns-file F --board ORG/N --folder DIR --stop-at N
//                       [--processes-file F] [--tokens] [--issues]
//
// Without --tokens it prints the agents that run now (lib/status-now.mjs, from the process list);
// with --tokens, or --issues, or where no agent runs, the page below.
//
// What it reads, all of it the project's own data:
// - the board: every card with its status, priority, state, parent and sub-issues, one JSON object
//   a line, and the status columns in the board's order, one a line; a package is an issue with
//   sub-issues, and names its worker in a "Worker: <session>" line of its body;
// - the team: team.tsv of the project folder, else the default of setup-ai-core;
// - the usage: ~/.ai-core/usage.json (now) and usage.log (the history the status line keeps);
// - the tokens: the session transcripts of this folder under ~/.claude/projects, read once and
//   cached per hour.
// What it computes: the pace (issues closed in the last 24 hours, shared by the workers), what an
// issue costs of the five-hour and the weekly window, and a plan that runs the packages on the
// workers in work order, pausing every worker where a window reaches the limit until it resets.
//
// For tests: AI_CORE_NOW stands in for the clock, AI_CORE_TRANSCRIPTS for ~/.claude/projects.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { render } from './status-now.mjs';

const DAY = 86400, HOUR = 3600, PACE_DAYS = 14, STEP = 900, HORIZON_DAYS = 60;

const A = { issues: false, tokens: false };
for (let i = 2; i < process.argv.length; i++) {
  const k = process.argv[i];
  if (k === '--issues') A.issues = A.tokens = true;
  else if (k === '--tokens') A.tokens = true;
  else if (k.startsWith('--')) A[k.slice(2)] = process.argv[++i];
}
const fail = (m) => { process.stderr.write(`error: ${m}\n`); process.exit(1); };
for (const k of ['items-file', 'columns-file', 'board', 'folder', 'stop-at']) if (!A[k]) fail(`--${k} is required`);
const now = Number(process.env.AI_CORE_NOW || Math.floor(Date.now() / 1000));
const home = process.env.AI_CORE_HOME || os.homedir();
const lines = (f) => fs.readFileSync(f, 'utf8').split('\n').map((l) => l.replace(/\r$/, '')).filter(Boolean);
const two = (n) => String(n).padStart(2, '0');
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const when = (s) => { const d = new Date(s * 1000); return `${DAYS[d.getDay()]} ${two(d.getDate())}.${two(d.getMonth() + 1)}. ${two(d.getHours())}:${two(d.getMinutes())}`; };

// --- the board -------------------------------------------------------------------------------
const org = A.board.split('/')[0];
const short = (repo) => (repo.startsWith(org + '/') ? repo.slice(org.length + 1) : repo);
const cols = lines(A['columns-file']);
const doneCol = cols.length ? cols[cols.length - 1] : 'Done';
// The work order: the column nearest done first, then the priority
const rank = (s) => { const i = cols.findIndex((c) => c.toLowerCase() === String(s).toLowerCase()); return i < 0 ? 999 : cols.length - i; };
const workOrder = (a, b) => rank(a.status) - rank(b.status) || a.prio.localeCompare(b.prio) || a.key.localeCompare(b.key);

const issues = lines(A['items-file']).map((l) => JSON.parse(l)).filter((n) => n.content && n.content.number).map((n) => {
  const c = n.content;
  const w = /^Worker:[ \t]*(\S+)/m.exec(c.body || '');
  return {
    key: `${short(c.repository.nameWithOwner)}#${c.number}`, title: c.title, open: c.state === 'OPEN',
    closedAt: c.closedAt ? Date.parse(c.closedAt) / 1000 : 0, status: n.status ? n.status.name : '-',
    prio: n.priority && /^P\d$/.test(n.priority.name) ? n.priority.name : 'P~',
    parent: c.parent ? `${short(c.parent.repository.nameWithOwner)}#${c.parent.number}` : null,
    subs: c.subIssuesSummary ? c.subIssuesSummary.total : 0, worker: w ? w[1] : null,
  };
});
if (!A.tokens) {
  const page = render({ folder: path.resolve(A.folder), board: A.board, now, when, cols,
    statuses: issues.map((i) => i.status), processes: A['processes-file'] ? lines(A['processes-file']) : [] });
  if (page) { process.stdout.write(page.join('\n') + '\n'); process.exit(0); }
}
const open = issues.filter((i) => i.open);
const packages = open.filter((i) => i.subs > 0).sort(workOrder);
const packageKeys = new Set(packages.map((p) => p.key));
// The work of a package is its open sub-issues that are no package themselves
const work = (p) => open.filter((i) => i.parent === p.key && !packageKeys.has(i.key));
const outside = open.filter((i) => !packageKeys.has(i.key) && !packageKeys.has(i.parent)).sort(workOrder);

// --- the team ----------------------------------------------------------------------------------
const folder = path.resolve(A.folder);
const prefix = path.basename(folder).slice(0, 3);
let teamFile = path.join(folder, '.ai-core', 'team.tsv');
if (!fs.existsSync(teamFile)) teamFile = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'templates', '.ai-core', 'team.tsv');
const members = [], seen = {};
for (const line of lines(teamFile)) {
  const [role, model, effort, count] = line.split('\t');
  if (!role || role.startsWith('#')) continue;
  for (let i = 0; i < Number(count); i++) {
    seen[model] = (seen[model] || 0) + 1;
    members.push({ name: `${prefix}-${model}-${seen[model]}`, model, effort, role });
  }
}
const workers = members.filter((m) => m.role === 'worker');

// --- the pace ----------------------------------------------------------------------------------
// The pace is the last 24 hours, the team as it runs now; a team that started within the 14 days
// would be planned at a fraction of its pace. The 14 days stay on the page for comparison.
const since = now - PACE_DAYS * DAY;
const closedDay = issues.filter((i) => !i.open && i.closedAt >= now - DAY);
const perDay = closedDay.length;
const perDayOver14 = issues.filter((i) => !i.open && i.closedAt >= since).length / PACE_DAYS;
// Per model where the packages that name their workers closed enough to measure, else shared evenly
const perModel = {};
for (const p of issues.filter((i) => i.worker)) {
  const m = (members.find((x) => x.name === p.worker) || {}).model;
  if (m) perModel[m] = (perModel[m] || 0) + closedDay.filter((i) => i.parent === p.key).length;
}
const measured = Object.values(perModel).reduce((a, b) => a + b, 0) >= 10;

// --- the usage ---------------------------------------------------------------------------------
const stopAt = Number(A['stop-at']);
let limits = {};
try { limits = JSON.parse(fs.readFileSync(path.join(home, '.ai-core', 'usage.json'), 'utf8')).rate_limits || {}; } catch { limits = {}; }
const windowOf = (k) => {
  const w = limits[k]; if (!w) return null;
  const reset = Number(w.resets_at || 0);
  return { used: reset && reset <= now ? 0 : Number(w.used_percentage || 0), reset };
};
const five = windowOf('five_hour'), week = windowOf('seven_day');

// --- the tokens --------------------------------------------------------------------------------
// What every session of this folder used in the last 24 hours: the coordinator, the workers and
// their agents alike, read per hour from the transcripts and each file read on from where the last
// run stopped. A session's tokens cannot be told apart by issue: a coordinator with a large context
// that steps into a worktree is no measure of that issue, so they are set against the issues closed
// in the same hours.
const windowStart = Math.ceil((now - DAY) / HOUR) * HOUR;
function tokensOfTheDay() {
  const root = process.env.AI_CORE_TRANSCRIPTS || path.join(os.homedir(), '.claude', 'projects');
  // Claude Code names a session's folder after its path, every other character a dash
  const enc = folder.replace(/[^A-Za-z0-9]/g, '-');
  const cacheFile = path.join(home, '.ai-core', `tokens${enc}.json`);
  let cache = {};
  try { cache = JSON.parse(fs.readFileSync(cacheFile, 'utf8')); } catch { cache = {}; }
  const files = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p); else if (e.name.endsWith('.jsonl')) files.push(p);
    }
  };
  // Every session of the machine is read, this folder's and the others', because the usage windows
  // are the account's and this folder carries only its share of their rise
  const ours = new Set();
  try {
    for (const e of fs.readdirSync(root, { withFileTypes: true })) {
      if (!e.isDirectory()) continue;
      const before = files.length;
      walk(path.join(root, e.name));
      if (e.name === enc || e.name.startsWith(enc + '-')) for (const f of files.slice(before)) ours.add(f);
    }
  } catch { /* no transcripts */ }
  const readLines = (text, c, ids) => {
    for (const line of text.split('\n')) {
      if (!line.includes('"usage"')) continue;
      let d; try { d = JSON.parse(line); } catch { continue; }
      const u = d.type === 'assistant' && d.message && d.message.usage;
      // One answer is written as several lines that repeat its usage; it is counted once
      if (!u || !d.timestamp || ids.has(d.message.id)) continue;
      ids.add(d.message.id);
      const hour = Math.floor(Date.parse(d.timestamp) / 1000 / HOUR) * HOUR;
      // per hour: fresh, read from the cache, the context all answers read, the answers, the largest
      const h = c.hours[hour] || (c.hours[hour] = [0, 0, 0, 0, 0]);
      const context = (u.input_tokens || 0) + (u.cache_creation_input_tokens || 0) + (u.cache_read_input_tokens || 0);
      // Fresh are the tokens not read back from the prompt cache, which the limits weigh the most
      h[0] += (u.input_tokens || 0) + (u.output_tokens || 0) + (u.cache_creation_input_tokens || 0);
      h[1] += u.cache_read_input_tokens || 0;
      h[2] = (h[2] || 0) + context; h[3] = (h[3] || 0) + 1; h[4] = Math.max(h[4] || 0, context);
    }
  };
  const kept = {};
  for (const f of files) {
    const st = fs.statSync(f);
    if (st.mtimeMs / 1000 < windowStart) continue;
    const c = cache[f] && cache[f].hours ? cache[f] : { off: 0, hours: {}, ids: [] };
    kept[f] = c;
    for (const h of Object.keys(c.hours)) if (Number(h) < windowStart) delete c.hours[h];
    if (st.size <= c.off) continue;
    const ids = new Set(c.ids);
    // Read in chunks, because a transcript runs to hundreds of megabytes
    const fd = fs.openSync(f, 'r');
    const chunk = Buffer.alloc(8 << 20);
    let rest = Buffer.alloc(0);
    for (let n; (n = fs.readSync(fd, chunk, 0, chunk.length, c.off + rest.length)) > 0;) {
      const buf = Buffer.concat([rest, chunk.subarray(0, n)]);
      const end = buf.lastIndexOf(0x0a) + 1; // a line still being written is read next time
      rest = buf.subarray(end);
      if (end) readLines(buf.subarray(0, end).toString('utf8'), c, ids);
      c.off += end;
    }
    fs.closeSync(fd);
    c.ids = [...ids].slice(-500);
  }
  try {
    fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
    fs.writeFileSync(cacheFile, JSON.stringify(kept));
  } catch (e) { process.stderr.write(`warning: the token cache ${cacheFile} was not written, so the next run reads every transcript again: ${e.message}\n`); }
  // byHour: this folder's fresh tokens and the machine's, hour by hour, for the cost below
  const sum = { fresh: 0, read: 0, context: 0, answers: 0, largest: 0, byHour: {} };
  for (const [f, c] of Object.entries(kept)) {
    for (const [h, [fresh, read, context, answers, largest]] of Object.entries(c.hours)) {
      if (Number(h) < windowStart) continue;
      const b = sum.byHour[h] || (sum.byHour[h] = [0, 0]);
      b[1] += fresh;
      if (!ours.has(f)) continue;
      b[0] += fresh;
      sum.fresh += fresh; sum.read += read;
      sum.context += context || 0; sum.answers += answers || 0; sum.largest = Math.max(sum.largest, largest || 0);
    }
  }
  return sum;
}
const tokens = tokensOfTheDay();
const closedInWindow = issues.filter((i) => !i.open && i.closedAt >= windowStart).length;

// How fast this folder raises a window while its sessions work: the rise of the window over the
// hours the usage log covers within the last 24, times this folder's share of the fresh tokens all
// sessions of the machine used in those hours, per hour. The windows are the account's, so the
// share keeps another project's work off this folder; and a window rises with the time worked, not
// with the issues closed, so the rate is per hour and the cost of an issue is derived from the pace.
// The pauses are foreseen from the whole account's rise, because every project fills the windows.
// Rises add up within one reset.
let share = 0;
function risePerHour(col) {
  let rows;
  try { rows = lines(path.join(home, '.ai-core', 'usage.log')).map((l) => l.split(' ')); } catch { return null; }
  rows = rows.filter((r) => Number(r[0]) >= windowStart && r[col] !== '-');
  if (rows.length < 2) return null;
  const from = Number(rows[0][0]), to = Number(rows[rows.length - 1][0]);
  let ours = 0, all = 0;
  for (const [h, [folderFresh, machineFresh]] of Object.entries(tokens.byHour)) {
    if (Number(h) + HOUR > from && Number(h) <= to) { ours += folderFresh; all += machineFresh; }
  }
  if (to - from < 2 * HOUR || !all) return null;
  share = ours / all;
  let rise = 0;
  for (let i = 1; i < rows.length; i++) {
    const d = Number(rows[i][col]) - Number(rows[i - 1][col]);
    if (rows[i][col + 1] === rows[i - 1][col + 1] && d > 0) rise += d;
  }
  const account = rise / ((to - from) / HOUR);
  return { account, folder: account * share };
}
const rise5 = risePerHour(1), riseW = risePerHour(3);
const rate5 = rise5 && rise5.folder, rateW = riseW && riseW.folder;
const measuredRise = rise5 !== null || riseW !== null;

// --- the plan ----------------------------------------------------------------------------------
// Every package with work left runs on one worker: the one its Worker: line names, else the lane
// that frees first. The issues outside packages are spread the same way, one by one.
const tasks = [
  ...packages.filter((p) => work(p).length).map((p) => ({ key: p.key, title: p.title, n: work(p).length, worker: p.worker })),
  ...outside.filter((i) => i.status !== doneCol).map((i) => ({ key: i.key, title: i.title, n: 1, worker: null, loose: true })),
];
// A Worker: line is taken as written. A session team.tsv does not name, one started by hand, takes
// over the last lane no package names, so there are as many lanes as the team has workers; where
// none is free it is a lane of its own. Its model is not known, so it runs at the shared pace.
const lanes = workers.map((w) => ({ ...w, queue: [] }));
const named = new Set(tasks.map((t) => t.worker).filter(Boolean));
for (const name of named) {
  if (lanes.some((l) => l.name === name)) continue;
  const free = [...lanes].reverse().find((l) => !named.has(l.name));
  if (free) Object.assign(free, { name, model: null, effort: null });
  else lanes.push({ name, model: null, effort: null, queue: [] });
}
for (const l of lanes) {
  l.rate = measured && l.model
    ? (perModel[l.model] || 0) / lanes.filter((x) => x.model === l.model).length
    : perDay / lanes.length;
}
for (const t of tasks.filter((x) => x.worker)) lanes.find((l) => l.name === t.worker).queue.push(t);
const busyUntil = (l) => (l.rate ? l.queue.reduce((s, t) => s + t.n, 0) / l.rate : Infinity);
for (const t of tasks.filter((x) => !x.worker)) {
  const l = lanes.reduce((a, b) => (busyUntil(b) < busyUntil(a) ? b : a), lanes[0]);
  if (l) { l.queue.push(t); t.planned = true; }
}

// The simulation: the lanes work their queues in quarter hours, the windows rise at the account's
// measured rate while any lane works, and a window at the limit stops every lane until it resets.
const pauses = [];
let u5 = five ? five.used : 0, r5 = five && five.reset > now ? five.reset : now + 5 * HOUR;
let uW = week ? week.used : 0, rW = week && week.reset > now ? week.reset : now + 7 * DAY;
for (const l of lanes) { l.at = 0; l.progress = 0; }
for (let t = now; t < now + HORIZON_DAYS * DAY && lanes.some((l) => l.at < l.queue.length);) {
  if (t >= r5) { u5 = 0; r5 = t + 5 * HOUR; }
  if (t >= rW) { uW = 0; rW = t + 7 * DAY; }
  const weekFull = riseW !== null && uW >= stopAt, fiveFull = rise5 !== null && u5 >= stopAt;
  if (weekFull || fiveFull) {
    const until = weekFull ? rW : r5;
    pauses.push({ from: t, until, which: weekFull ? 'week' : '5h' });
    t = until; continue;
  }
  u5 += (rise5 ? rise5.account : 0) * STEP / HOUR; uW += (riseW ? riseW.account : 0) * STEP / HOUR;
  for (const l of lanes) {
    if (l.at >= l.queue.length || !l.rate) continue;
    const task = l.queue[l.at];
    if (task.start === undefined) task.start = t;
    l.progress += (l.rate / DAY) * STEP;
    while (l.progress >= 1 && l.at < l.queue.length) {
      l.progress -= 1;
      task.done = (task.done || 0) + 1;
      if (task.done >= task.n) { task.end = t + STEP; l.at++; break; }
    }
  }
  t += STEP;
}
const unfinished = tasks.filter((x) => x.end === undefined).length;
const finish = Math.max(now, ...tasks.map((x) => x.end || 0));

// --- the page ----------------------------------------------------------------------------------
const fit = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s.padEnd(n));
const count = (n) => (n >= 1e9 ? `${(n / 1e9).toFixed(1)}G` : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : String(Math.round(n)));
const name = (s) => s.replace(/^Package:\s*/i, '');
const W = { key: 26, title: 34, left: 4, start: 16 };
const row = (mark, key, title, left, start, end) =>
  `    ${mark} ${fit(key, W.key)} ${fit(title, W.title)} ${String(left).padStart(W.left)}  ${fit(start, W.start)} ${end}`;
const out = [];
const windowText = (w, label) => (w ? `${label} ${Math.floor(w.used)} % (reset ${when(w.reset)})` : `${label} not recorded`);
const ready = packages.filter((p) => !open.some((i) => i.parent === p.key));
const mismatch = open.filter((i) => i.status === doneCol);

out.push(`${path.basename(folder)} · board ${A.board} · ${when(now)}`);
out.push(`usage   ${windowText(five, '5h')} · ${windowText(week, 'week')} · limit ${stopAt} %`);
out.push(`pace    ${perDay} issues closed in the last 24 hours, ${perDayOver14.toFixed(1)} a day over ${PACE_DAYS} days; ${lanes.length} workers` +
  (measured ? ', per model from the packages they finished' : ', shared evenly: too few packages name their worker'));
const perIssue = (rate) => (rate !== null && rate !== undefined && perDay ? `${(rate / (perDay / 24)).toFixed(2)} %` : 'an unmeasured part');
out.push(`cost    ${measuredRise
  ? `this folder raises the 5h window ${rise5 ? `${rate5.toFixed(1)} %` : 'by an unmeasured part'} and the week ${riseW ? `${rateW.toFixed(2)} %` : 'by an unmeasured part'} an hour, ${Math.round(share * 100)} % of the machine's fresh tokens; at the pace of 24 hours, ${perIssue(rateW)} of the week per issue closed here`
  : 'what the work costs of a window is not measured yet: the status line has logged the usage for less than two hours'}`);
out.push(`tokens  ${tokens.fresh + tokens.read
  ? `in 24 hours the sessions of this folder used ${count(tokens.fresh)} fresh and read ${count(tokens.read)} from the cache` +
    (closedInWindow ? `: ${count(tokens.fresh / closedInWindow)} fresh and ${count(tokens.read / closedInWindow)} from the cache per closed issue` : ', and closed no issue')
  : 'no session of this folder answered in the last 24 hours'}`);
// The context an answer reads again: the measure of how late the sessions compact
out.push(`context ${tokens.answers
  ? `${count(tokens.context / tokens.answers)} per answer on average, ${count(tokens.largest)} the largest, over ${tokens.answers} answers in 24 hours`
  : 'no session of this folder answered in the last 24 hours'}`);
out.push(`open    ${open.length} issues · ${packages.length} packages, ${ready.length} ready to close · ${outside.length} outside packages`);
out.push('');
out.push(`PLAN BY WORKER${' '.repeat(6 + W.key + 1 + W.title + 1 - 14)}${'left'.padStart(W.left)}  ${'start'.padEnd(W.start)} end`);
const endText = (x) => (x.end !== undefined ? when(x.end) : `after ${HORIZON_DAYS} days`);
for (const l of lanes) {
  out.push(`  ${l.name}  ${l.model ? `${l.model} ${l.effort}` : 'a model team.tsv does not name'}  ${l.rate ? `${l.rate.toFixed(1)} issues a day` : 'no pace'}`);
  for (const q of l.queue.filter((x) => !x.loose)) out.push(row(q.planned ? '·' : '▸', q.key, name(q.title), q.n, q.start !== undefined ? when(q.start) : '-', endText(q)));
  const loose = l.queue.filter((x) => x.loose);
  if (loose.length) {
    const first = loose.find((x) => x.start !== undefined);
    const last = loose.some((x) => x.end === undefined) ? { end: undefined } : { end: Math.max(...loose.map((x) => x.end)) };
    out.push(row('·', 'outside packages', `${loose.length} issue${loose.length === 1 ? '' : 's'}`, loose.length, first ? when(first.start) : '-', endText(last)));
  }
}
out.push('    ▸ named by its Worker: line   · planned on the worker that frees first');
out.push('');
out.push(pauses.length
  ? `PAUSES  ${pauses.slice(0, 3).map((p) => `${p.which} ${when(p.from)} until ${when(p.until)}`).join(' · ')}${pauses.length > 3 ? ` · ${pauses.length - 3} more` : ''}`
  : `PAUSES  ${measuredRise ? `none: no window reaches ${stopAt} %` : 'unknown: no usage history yet to measure what the work costs'}`);
out.push(unfinished
  ? `DONE    not within ${HORIZON_DAYS} days: ${unfinished} of ${tasks.length} pieces of work are left at this pace`
  : `DONE    about ${when(finish)}, an estimate from the pace of the last 24 hours${measuredRise ? ', the measured rise of the windows and the pauses' : ''}`);
if (ready.length) out.push(`CLOSE   every sub-issue closed: ${ready.map((p) => p.key).join(' ')}`);
if (mismatch.length) out.push(`CHECK   open on ${doneCol}: ${mismatch.map((i) => i.key).join(' ')}`);

if (A.issues) {
  out.push('');
  out.push('OPEN ISSUES BY PACKAGE');
  const group = (title, list) => {
    if (!list.length) return;
    out.push(`  ${title} (${list.length})`);
    for (const i of list.sort(workOrder)) out.push(`    ${i.prio === 'P~' ? '--' : i.prio}  ${fit(i.key, W.key)} ${fit(i.title, 60)} ${i.status}`);
  };
  for (const p of packages) group(`${p.key} ${name(p.title)}`, work(p));
  group('outside packages', outside);
}
process.stdout.write(out.join('\n') + '\n');
