// What runs now and what is left up to the next goal, the default page of `ai-core status`:
// the board counts, who works on what, the open steps up to the goal, and what closes next.
// Everything is read, nothing is estimated by a model: the board, the project's plan file, the
// process list the twins hand over, and the workers' logs.
//
// The plan file, <project folder>/.ai-core/plan.json, written by the coordinator:
//   { "goal": "...", "coordinator": "<session>",
//     "workers": [ { "name", "tool", "model", "effort", "match", "log", "issues", "now", "next" } ],
//     "steps": [ { "step", "who", "state", "next", "closes", "eta" } ] }
// A worker runs where its "match" text stands in the command line of a process. Its log gives
// the minutes since its last report (the last line with a timestamp in its first 40 characters)
// and what it does now and next (its last "NOW:" and "NEXT:" lines, else "now" and "next").

import fs from 'node:fs';
import path from 'node:path';

const TS = /(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2})?)/;
// A side run: an agent CLI started to answer one prompt, not a worker of its own
const SIDE = [
  ['codex', /(^|[\\/\s])codex(\.exe)?\s+exec\b/],
  ['agy', /(^|[\\/\s])agy(\.exe)?\s(.*\s)?(-p|--print)\b/],
  ['claude', /(^|[\\/\s])claude(\.exe)?\s(.*\s)?(-p|--print)\b/],
  ['gemini', /(^|[\\/\s])gemini(\.exe)?\s(.*\s)?(-p|--prompt)\b/],
];

// "[[dd-]hh:]mm:ss" as ps writes it, or plain seconds as status.ps1 writes them
const seconds = (t) => {
  if (/^\d+$/.test(t)) return Number(t);
  const [d, rest] = t.includes('-') ? t.split('-') : ['0', t];
  return Number(d) * 86400 + rest.split(':').reduce((s, x) => s * 60 + Number(x), 0);
};

function readLog(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return {}; }
  const out = {};
  for (const line of text.split('\n').map((l) => l.trim()).filter(Boolean)) {
    const m = TS.exec(line.slice(0, 40));
    if (m) out.at = Date.parse(`${m[1]}T${m[2].length === 5 ? m[2] + ':00' : m[2]}Z`) / 1000;
    const n = /\bNOW:\s*(.+)$/.exec(line); if (n) out.now = n[1];
    const x = /\bNEXT:\s*(.+)$/.exec(line); if (x) out.next = x[1];
  }
  return out;
}

// A table drawn with box characters: fixed widths, each cell wrapped inside its column
function table(head, rows, widths) {
  const wrap = (s, w) => {
    const out = [];
    for (const word of String(s ?? '').split(/\s+/).filter(Boolean)) {
      for (let rest = word; rest.length;) {
        const last = out.length - 1;
        if (last >= 0 && out[last].length + 1 + rest.length <= w) { out[last] += ' ' + rest; rest = ''; }
        else { out.push(rest.slice(0, w)); rest = rest.slice(w); }
      }
    }
    return out.length ? out : [''];
  };
  const rule = (l, m, r) => l + widths.map((w) => '─'.repeat(w + 2)).join(m) + r;
  const cells = (row) => {
    const parts = row.map((c, i) => wrap(c, widths[i]));
    const h = Math.max(...parts.map((p) => p.length));
    return Array.from({ length: h }, (_, i) => '│' + parts.map((p, j) => ` ${(p[i] || '').padEnd(widths[j])} `).join('│') + '│');
  };
  return [rule('┌', '┬', '┐'), ...cells(head), rule('├', '┼', '┤'), ...rows.flatMap(cells), rule('└', '┴', '┘')];
}

export function render({ folder, board, now, when, cols, statuses, processesFile, fail }) {
  const out = [];
  const counts = cols.map((c) => `${c} ${statuses.filter((s) => s.toLowerCase() === c.toLowerCase()).length}`);
  out.push(`${path.basename(folder)} · board ${board} · ${when(now)} · ${counts.join(' · ')}`);
  const planFile = path.join(folder, '.ai-core', 'plan.json');
  if (!fs.existsSync(planFile)) {
    out.push('', `no plan: ${planFile} is missing, so who works on what and the steps up to the goal are not known;`,
      'the coordinator writes it, and `ai-core status --help` gives its shape. `ai-core status --tokens` prints the pace and the forecast.');
    return out;
  }
  let plan;
  try { plan = JSON.parse(fs.readFileSync(planFile, 'utf8')); } catch (e) { fail(`${planFile} is no valid JSON: ${e.message}`); }
  const workers = plan.workers || [], steps = plan.steps || [], coordinator = plan.coordinator || 'the coordinator';

  const procs = new Map();
  if (processesFile) {
    for (const line of fs.readFileSync(processesFile, 'utf8').split('\n')) {
      const [pid, ppid, age, ...args] = line.replace(/\r$/, '').split('\t');
      if (pid && args.length) procs.set(pid, { ppid, secs: seconds(age), args: args.join('\t') });
    }
  }
  const sideTool = (args) => (SIDE.find(([, re]) => re.test(args)) || [])[0];
  const workerIn = (args) => workers.find((w) => w.match && args.includes(w.match));
  const ownerOf = (pid) => {
    for (let p = pid, i = 0; procs.has(p) && i < 40; p = procs.get(p).ppid, i++) {
      const w = workerIn(procs.get(p).args); if (w) return w.name;
    }
    return coordinator;
  };
  const runs = [];
  for (const [pid, p] of procs) {
    const tool = sideTool(p.args);
    if (!tool || workerIn(p.args)) continue;
    const parent = procs.get(p.ppid);
    if (parent && sideTool(parent.args)) continue;
    const model = /(?:\s-m|\s--model)[ =](\S+)/.exec(p.args), effort = /model_reasoning_effort=(\w+)|--effort[ =](\w+)/.exec(p.args);
    const kind = / exec resume\b/.test(p.args) ? 'resumed run' : / fork\b/.test(p.args) ? 'review fork' : 'run';
    runs.push({ owner: ownerOf(p.ppid), tool, kind, minutes: Math.round(p.secs / 60),
      model: model ? model[1] : '?', effort: effort ? effort[1] || effort[2] : '',
      topic: [...new Set(p.args.match(/[\w.-]*#\d+/g) || [])].slice(0, 3).join(' ') });
  }
  runs.sort((a, b) => a.minutes - b.minutes);

  const rows = [], running = {};
  const add = (tool) => { running[tool] = (running[tool] || 0) + 1; };
  const sideRows = (name) => runs.filter((r) => r.owner === name).map((r) => {
    add(r.tool);
    return [`  └ ${r.tool}`, [r.model, r.effort].filter(Boolean).join(' · '), `running (${r.minutes} min)`, r.topic, r.kind, ''];
  });
  const all = [...procs.values()].map((p) => p.args);
  for (const w of workers) {
    const log = w.log ? readLog(path.resolve(folder, w.log)) : {};
    const on = Boolean(w.match) && all.some((a) => a.includes(w.match));
    if (on) add(w.tool || '?');
    const age = log.at ? ` (${Math.max(0, Math.round((now - log.at) / 60))} min)` : '';
    rows.push([w.name, [w.model, w.effort].filter(Boolean).join(' · '), `${on ? 'running' : 'off'}${age}`, w.issues || '', log.now || w.now || '', log.next || w.next || '']);
    rows.push(...sideRows(w.name));
  }
  for (const owner of new Set(runs.map((r) => r.owner).filter((o) => !workers.some((w) => w.name === o)))) {
    rows.push([owner, '', '', '', 'coordinates', '']);
    rows.push(...sideRows(owner));
  }
  out.push('', 'WHO WORKS ON WHAT');
  out.push(...table(['worker', 'model', 'state (last report)', 'issues', 'now', 'next'], rows, [12, 26, 16, 18, 32, 26]));

  const left = steps.filter((s) => String(s.state || '').toLowerCase() !== 'done');
  out.push('', `UP TO ${String(plan.goal || 'the goal').toUpperCase()}`);
  out.push(...table(['#', 'step', 'who', 'state', 'next step'], left.map((s, i) => [i + 1, s.step, s.who, s.state, s.next]), [3, 40, 18, 16, 44]));

  const total = Object.values(running).reduce((a, b) => a + b, 0);
  out.push('', `AGENTS        ${total} active${total ? `: ${Object.entries(running).map(([t, n]) => `${n} ${t}`).join(', ')}` : ''} · coordinated by ${coordinator}`);
  const soon = left.filter((s) => Number(s.closes) > 0);
  out.push(`NEXT TO DONE  ${soon.reduce((a, s) => a + Number(s.closes), 0)} cards, the times approximate`);
  for (const s of soon) out.push(`  ${String(s.closes).padStart(3)}  ~ ${String(s.eta || '').padEnd(18)} ${s.step}`);
  return out;
}
