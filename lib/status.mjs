// The state of the work on one board and the plan for the rest, counted, never written by a model.
// bin/status.sh and bin/status.ps1 read the board and start this, so the two spellings print the
// same plan by construction.
//
//   node lib/status.mjs --items-file F --columns-file F --board ORG/N --folder DIR --stop-at N [--issues]
//
// What it reads, all of it the project's own data:
// - the board: every card with its status, priority, state, parent and sub-issues, one JSON object
//   a line, and the status columns in the board's order, one a line; a package is an issue with
//   sub-issues, and names its worker in a "Worker: <session>" line of its body;
// - the team: team.tsv of the project folder, else the default of setup-ai-core;
// - the usage: ~/.ai-core/usage.json (now) and usage.log (the history the status line keeps);
// - the tokens: the session transcripts of this folder under ~/.claude/projects, read once and
//   cached, a session's tokens counted to the issue whose worktree it last worked in.
// What it computes: the pace (issues closed per worker and day over 14 days), what an issue costs of
// the five-hour and the weekly window, and a plan that runs the packages on the workers in work
// order, pausing every worker where a window reaches the limit until it resets.
//
// For tests: AI_CORE_NOW stands in for the clock, AI_CORE_TRANSCRIPTS for ~/.claude/projects.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DAY = 86400, HOUR = 3600, PACE_DAYS = 14, STEP = 900, HORIZON_DAYS = 60;

const A = { issues: false };
for (let i = 2; i < process.argv.length; i++) {
  const k = process.argv[i];
  if (k === '--issues') A.issues = true;
  else if (k.startsWith('--')) A[k.slice(2)] = process.argv[++i];
}
const fail = (m) => { process.stderr.write(`error: ${m}\n`); process.exit(1); };
for (const k of ['items-file', 'columns-file', 'board', 'folder', 'stop-at']) if (!A[k]) fail(`--${k} is required`);
const now = Number(process.env.AI_CORE_NOW || Math.floor(Date.now() / 1000));
const home = process.env.AI_CORE_HOME || os.homedir();
const lines = (f) => fs.readFileSync(f, 'utf8').split('\n').map((l) => l.replace(/\r$/, '')).filter(Boolean);

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
const since = now - PACE_DAYS * DAY;
const closedRecent = issues.filter((i) => !i.open && i.closedAt >= since);
const perDay = closedRecent.length / PACE_DAYS;
// Per model where the packages that name their workers closed enough to measure, else shared evenly
const perModel = {};
for (const p of issues.filter((i) => i.worker)) {
  const m = (members.find((x) => x.name === p.worker) || {}).model;
  if (m) perModel[m] = (perModel[m] || 0) + closedRecent.filter((i) => i.parent === p.key).length;
}
const measured = Object.values(perModel).reduce((a, b) => a + b, 0) >= 10;
const rateOf = (w) => (measured
  ? (perModel[w.model] || 0) / PACE_DAYS / workers.filter((x) => x.model === w.model).length
  : (workers.length ? perDay / workers.length : 0));

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
// What a closed issue costs of a window: the rise of the window over the logged history, against the
// issues this board closed in the same time. The window is the whole account's, so work on other
// boards counts here too and the cost is the higher for it. Rises add up within one reset.
function costPerIssue(col) {
  let rows;
  try { rows = lines(path.join(home, '.ai-core', 'usage.log')).map((l) => l.split(' ')); } catch { return null; }
  rows = rows.filter((r) => Number(r[0]) >= since && r[col] !== '-');
  if (rows.length < 2) return null;
  let rise = 0;
  for (let i = 1; i < rows.length; i++) {
    const d = Number(rows[i][col]) - Number(rows[i - 1][col]);
    if (rows[i][col + 1] === rows[i - 1][col + 1] && d > 0) rise += d;
  }
  const from = Number(rows[0][0]), to = Number(rows[rows.length - 1][0]);
  const n = issues.filter((i) => !i.open && i.closedAt >= from && i.closedAt <= to).length;
  return to - from >= 2 * HOUR && n > 0 ? rise / n : null;
}
const cost5 = costPerIssue(1), costW = costPerIssue(3);

// --- the tokens --------------------------------------------------------------------------------
// The transcripts of the sessions in this folder, each read on from where the last run stopped
function tokensPerIssue() {
  const root = process.env.AI_CORE_TRANSCRIPTS || path.join(os.homedir(), '.claude', 'projects');
  // Claude Code names a session's folder after its path, every other character a dash
  const enc = folder.replace(/[^A-Za-z0-9]/g, '-');
  const inFolder = (cwd) => { const c = path.resolve(cwd); return c === folder || c.startsWith(folder + path.sep); };
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
  try { for (const e of fs.readdirSync(root)) if (e === enc || e.startsWith(enc + '-')) walk(path.join(root, e)); } catch { return {}; }
  const readLines = (text, c, ids) => {
    for (const line of text.split('\n')) {
      if (!line) continue;
      let d; try { d = JSON.parse(line); } catch { continue; }
      // A session works on the issue whose worktree it stands in, and on none outside one
      if (d.cwd && inFolder(d.cwd)) {
        const m = /[\\/]\.worktrees[\\/]([^\\/]+)[\\/]issue-(\d+)-/.exec(d.cwd);
        c.issue = m ? `${m[1]}#${m[2]}` : null;
      }
      const u = d.type === 'assistant' && d.message && d.message.usage;
      // One answer is written as several lines that repeat its usage; it is counted once
      if (!u || !c.issue || ids.has(d.message.id)) continue;
      ids.add(d.message.id);
      // Fresh are the tokens not read back from the prompt cache, which the limits weigh the most
      const fresh = (u.input_tokens || 0) + (u.output_tokens || 0) + (u.cache_creation_input_tokens || 0);
      const s = c.sums[c.issue] || (c.sums[c.issue] = [0, 0]);
      s[0] += fresh + (u.cache_read_input_tokens || 0); s[1] += fresh;
    }
  };
  for (const f of files) {
    const st = fs.statSync(f);
    if (st.mtimeMs / 1000 < since) continue;
    const c = cache[f] || { off: 0, sums: {}, issue: null, ids: [] };
    cache[f] = c;
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
    fs.writeFileSync(cacheFile, JSON.stringify(cache));
  } catch (e) { process.stderr.write(`warning: the token cache ${cacheFile} was not written, so the next run reads every transcript again: ${e.message}\n`); }
  const sums = {};
  for (const c of Object.values(cache)) {
    for (const [k, [all, fresh]] of Object.entries(c.sums)) { const s = sums[k] || (sums[k] = [0, 0]); s[0] += all; s[1] += fresh; }
  }
  return sums;
}
const tokens = tokensPerIssue();
const measuredIssues = closedRecent.filter((i) => tokens[i.key]);
const median = (j) => { const v = measuredIssues.map((i) => tokens[i.key][j]).sort((a, b) => a - b); return v[Math.floor(v.length / 2)]; };

// --- the plan ----------------------------------------------------------------------------------
// Every package with work left runs on one worker: the one its Worker: line names, else the lane
// that frees first. The issues outside packages are spread the same way, one by one.
const tasks = [
  ...packages.filter((p) => work(p).length).map((p) => ({ key: p.key, title: p.title, n: work(p).length, worker: p.worker })),
  ...outside.filter((i) => i.status !== doneCol).map((i) => ({ key: i.key, title: i.title, n: 1, worker: null, loose: true })),
];
const lanes = workers.map((w) => ({ ...w, rate: rateOf(w), queue: [] }));
for (const t of tasks) if (t.worker && !lanes.some((l) => l.name === t.worker)) t.worker = null;
for (const t of tasks.filter((x) => x.worker)) lanes.find((l) => l.name === t.worker).queue.push(t);
const busyUntil = (l) => (l.rate ? l.queue.reduce((s, t) => s + t.n, 0) / l.rate : Infinity);
for (const t of tasks.filter((x) => !x.worker)) {
  const l = lanes.reduce((a, b) => (busyUntil(b) < busyUntil(a) ? b : a), lanes[0]);
  if (l) { l.queue.push(t); t.planned = true; }
}

// The simulation: the lanes work their queues in quarter hours; each finished issue adds its cost to
// the windows, and a window at the limit stops every lane until it resets.
const pauses = [];
let u5 = five ? five.used : 0, r5 = five && five.reset > now ? five.reset : now + 5 * HOUR;
let uW = week ? week.used : 0, rW = week && week.reset > now ? week.reset : now + 7 * DAY;
for (const l of lanes) { l.at = 0; l.progress = 0; }
for (let t = now; t < now + HORIZON_DAYS * DAY && lanes.some((l) => l.at < l.queue.length);) {
  if (t >= r5) { u5 = 0; r5 = t + 5 * HOUR; }
  if (t >= rW) { uW = 0; rW = t + 7 * DAY; }
  const weekFull = costW !== null && uW >= stopAt, fiveFull = cost5 !== null && u5 >= stopAt;
  if (weekFull || fiveFull) {
    const until = weekFull ? rW : r5;
    pauses.push({ from: t, until, which: weekFull ? 'week' : '5h' });
    t = until; continue;
  }
  for (const l of lanes) {
    if (l.at >= l.queue.length || !l.rate) continue;
    const task = l.queue[l.at];
    if (task.start === undefined) task.start = t;
    l.progress += (l.rate / DAY) * STEP;
    while (l.progress >= 1 && l.at < l.queue.length) {
      l.progress -= 1;
      task.done = (task.done || 0) + 1;
      u5 += cost5 || 0; uW += costW || 0;
      if (task.done >= task.n) { task.end = t + STEP; l.at++; break; }
    }
  }
  t += STEP;
}
const unfinished = tasks.filter((x) => x.end === undefined).length;
const finish = Math.max(now, ...tasks.map((x) => x.end || 0));

// --- the page ----------------------------------------------------------------------------------
const two = (n) => String(n).padStart(2, '0');
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const when = (s) => { const d = new Date(s * 1000); return `${DAYS[d.getDay()]} ${two(d.getDate())}.${two(d.getMonth() + 1)}. ${two(d.getHours())}:${two(d.getMinutes())}`; };
const fit = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s.padEnd(n));
const count = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : String(n));
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
out.push(`pace    ${perDay.toFixed(1)} issues a day over ${PACE_DAYS} days, ${lanes.length} workers` +
  (measured ? ', per model from the packages they finished' : ', shared evenly: too few packages name their worker'));
out.push(`cost    ${cost5 !== null || costW !== null
  ? `an issue closed here raises the 5h window ${cost5 !== null ? `${cost5.toFixed(1)} %` : 'by an unmeasured part'} and the week ${costW !== null ? `${costW.toFixed(2)} %` : 'by an unmeasured part'}`
  : 'what an issue costs of a window is not measured yet: the status line has logged the usage for less than two hours'}`);
out.push(`tokens  ${measuredIssues.length
  ? `${count(median(0))} per issue, ${count(median(1))} of them fresh, not read from the cache (median of ${measuredIssues.length} closed issues)`
  : 'no closed issue of the last 14 days was worked on in a worktree of this folder'}`);
out.push(`open    ${open.length} issues · ${packages.length} packages, ${ready.length} ready to close · ${outside.length} outside packages`);
out.push('');
out.push(`PLAN BY WORKER${' '.repeat(6 + W.key + 1 + W.title + 1 - 14)}${'left'.padStart(W.left)}  ${'start'.padEnd(W.start)} end`);
const endText = (x) => (x.end !== undefined ? when(x.end) : `after ${HORIZON_DAYS} days`);
for (const l of lanes) {
  out.push(`  ${l.name}  ${l.model} ${l.effort}  ${l.rate ? `${l.rate.toFixed(1)} issues a day` : 'no pace'}`);
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
  : `PAUSES  ${cost5 !== null || costW !== null ? `none: no window reaches ${stopAt} %` : 'unknown: no usage history yet to measure what an issue costs'}`);
out.push(unfinished
  ? `DONE    not within ${HORIZON_DAYS} days: ${unfinished} of ${tasks.length} pieces of work are left at this pace`
  : `DONE    about ${when(finish)}, an estimate from the pace of ${PACE_DAYS} days${cost5 !== null || costW !== null ? ', the cost per issue and the pauses' : ''}`);
if (ready.length) out.push(`CLOSE   every sub-issue closed: ${ready.map((p) => p.key).join(' ')}`);
if (mismatch.length) out.push(`CHECK   open on ${doneCol}: ${mismatch.map((i) => i.key).join(' ')}`);

if (A.issues) {
  out.push('');
  out.push('OPEN ISSUES BY PACKAGE');
  const group = (title, list) => {
    if (!list.length) return;
    out.push(`  ${title} (${list.length})`);
    for (const i of list.sort(workOrder)) out.push(`    ${i.prio === 'P~' ? '--' : i.prio}  ${fit(i.key, W.key)} ${fit(i.title, 60)} ${i.status}${tokens[i.key] ? `  ${count(tokens[i.key][0])} tokens` : ''}`);
  };
  for (const p of packages) group(`${p.key} ${name(p.title)}`, work(p));
  group('outside packages', outside);
}
process.stdout.write(out.join('\n') + '\n');
