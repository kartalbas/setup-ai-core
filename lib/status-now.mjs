// What runs now, the default page of `ai-core status`: the board counts and every agent process on
// this machine, with the runs each one started nested under it, and the command that reaches each.
// Only what is measured is shown: the board, the process list, Claude Code's list of its sessions
// and the codex files the processes hold open, as the twins hand them over. Who works on what and
// what comes next is the coordinator's to say, from what it knows; the person-in-charge skill
// builds that table on top.
//
// The process list, one process a line: pid, parent pid, time running ([[dd-]hh:]mm:ss as ps
// writes it, or plain seconds as status.ps1 writes them) and the command line, a tab between.

const TOOLS = ['claude', 'codex', 'agy', 'gemini'];
// The CLI is the command itself (its path and extension aside, or run by node), never a word in
// another command
const cli = (name) => new RegExp(`^(?:"?\\S*node(?:\\.exe)?"?\\s+)?"?(?:\\S*[\\\\/])?${name}(?:\\.exe|\\.cmd|\\.js)?"?(?:\\s|$)`);
// Claude Code runs a background session from its versioned binary, .../claude/versions/<version>
const CLAUDE_BINARY = /^"?\S*[\\/]claude[\\/]versions[\\/]\d+\.\d+\.\d+(?:\.exe)?"?(?:\s|$)/;
// A run answers one prompt and ends; everything else of the CLI is a session
const RUN = {
  codex: /\sexec(?:\s|$)/,
  agy: /\s(?:-p|--print|--prompt)(?:[\s=]|$)/,
  claude: /\s(?:-p|--print)(?:[\s=]|$)/,
  gemini: /\s(?:-p|--prompt)(?:[\s=]|$)/,
};
// A process of the CLI that is no agent: Claude Code's bridge to the Chrome extension, and the
// daemon and the terminal host that carry its background sessions
const HELPER = /\s--chrome-native-host(?:\s|$)|^(?:"?\S*node(?:\.exe)?"?\s+)?"?\S+"?\s+(?:daemon|bg-pty-host)(?:\s|$)/;
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

// The command that reaches each agent, by pid, from what its CLI reports and nothing guessed:
// `claude agents --json` names every Claude session with its pid, and a codex process holds its
// rollout-<time>-<uuid>.jsonl open, a line "/proc/<pid>/fd<tab><path>" where the system shows it.
// A running background session is reached with attach: --resume would start a second process
// on the same session.
function reachOf(claudeAgents, rollouts) {
  const reach = new Map(), notes = [];
  if (claudeAgents.trim()) {
    let list = null;
    try { list = JSON.parse(claudeAgents); } catch { /* reported below */ }
    if (!Array.isArray(list)) notes.push(`claude agents --json gave no list: ${claudeAgents.trim().split('\n')[0].slice(0, 60)}`);
    for (const a of Array.isArray(list) ? list : []) {
      const command = a.kind === 'background' && a.id ? `claude attach ${a.id}` : a.sessionId ? `claude --resume ${a.sessionId}` : '';
      if (a.pid && command) reach.set(`claude ${a.pid}`, { name: a.name || '', command });
    }
  }
  for (const line of rollouts) {
    const m = new RegExp(`[\\\\/](\\d+)[\\\\/]fd\\t.*rollout-.*(${UUID})\\.jsonl$`).exec(line);
    if (m) reach.set(`codex ${m[1]}`, { name: '', command: `codex resume ${m[2]}` });
  }
  return { reach, notes };
}

const seconds = (t) => {
  if (/^\d+$/.test(t)) return Number(t);
  const [d, rest] = t.includes('-') ? t.split('-') : ['0', t];
  return Number(d) * 86400 + rest.split(':').reduce((s, x) => s * 60 + Number(x), 0);
};

// A table drawn with box characters: fixed widths, each cell wrapped inside its column
function table(head, rows, widths) {
  const wrap = (s, w) => {
    const indent = /^\s*/.exec(String(s ?? ''))[0], out = indent ? [indent.slice(0, w - 1)] : [];
    for (const word of String(s ?? '').split(/\s+/).filter(Boolean)) {
      for (let rest = word; rest.length;) {
        const last = out.length - 1;
        const sep = out[last] && out[last].trim() ? ' ' : '';
        if (last >= 0 && out[last].length + sep.length + rest.length <= w) { out[last] += sep + rest; rest = ''; }
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

// The page, or null where no agent runs: the caller then prints the pace and the forecast
export function render({ folder, board, now, when, cols, statuses, processes, claudeAgents = '', rollouts = [] }) {
  const procs = new Map();
  for (const line of processes) {
    const [pid, ppid, age, ...args] = line.split('\t');
    if (pid && args.length) procs.set(pid, { pid, ppid, secs: seconds(age), args: args.join('\t') });
  }
  const agents = new Map();
  for (const p of procs.values()) {
    const tool = TOOLS.find((t) => cli(t).test(p.args) || (t === 'claude' && CLAUDE_BINARY.test(p.args)));
    if (tool && !HELPER.test(p.args)) agents.set(p.pid, { ...p, tool });
  }
  if (!agents.size) return null;
  // The agent that started a process: the nearest agent among its ancestors
  const ownerOf = (a) => {
    for (let p = a.ppid, i = 0; procs.has(p) && i < 64; p = procs.get(p).ppid, i++) if (agents.has(p)) return p;
    return null;
  };
  const children = new Map();
  for (const a of agents.values()) {
    a.owner = ownerOf(a);
    if (a.owner) children.set(a.owner, [...(children.get(a.owner) || []), a]);
  }
  const rows = [], count = {}, order = [];
  const walk = (a, depth) => {
    count[a.tool] = (count[a.tool] || 0) + 1;
    order.push(a);
    const model = /(?:\s-m|\s--model)[ =](\S+)/.exec(a.args), effort = /model_reasoning_effort=(\w+)|--effort[ =](\w+)/.exec(a.args);
    const name = /\s(?:--resume|-r|--name|-n)[ =]([^\s-]\S*)/.exec(a.args);
    const kind = RUN[a.tool].test(a.args) ? (/\sexec\s+resume\b/.test(a.args) ? 'resumed run' : 'run') : 'session';
    rows.push([`${'  '.repeat(depth)}${depth ? '└ ' : ''}${a.tool}${name ? ' ' + name[1].slice(0, 12) : ''}`, a.pid,
      [model ? model[1] : '', effort ? effort[1] || effort[2] : ''].filter(Boolean).join(' · '),
      `${Math.round(a.secs / 60)} min`, [...new Set(a.args.match(/[\w.-]*#\d+/g) || [])].slice(0, 3).join(' '), kind]);
    for (const c of (children.get(a.pid) || []).sort((x, y) => x.secs - y.secs)) walk(c, depth + 1);
  };
  for (const a of [...agents.values()].filter((x) => !x.owner).sort((x, y) => y.secs - x.secs)) walk(a, 0);

  const counts = cols.map((c) => `${c} ${statuses.filter((s) => s.toLowerCase() === c.toLowerCase()).length}`);
  const total = Object.values(count).reduce((a, b) => a + b, 0);
  const { reach, notes } = reachOf(claudeAgents, rollouts);
  const reachLine = (a) => {
    const r = reach.get(`${a.tool} ${a.pid}`);
    return `  ${a.pid.padEnd(8)} ${((r && r.name) || a.tool).padEnd(28)} ${r ? r.command : '—'}`;
  };
  return [
    `${folder.split(/[\\/]/).pop()} · board ${board} · ${when(now)} · ${counts.join(' · ')}`,
    '', 'AGENTS ON THIS MACHINE',
    ...table(['agent', 'pid', 'model', 'running', 'issues', 'kind'], rows, [22, 8, 26, 9, 22, 11]),
    '', `AGENTS  ${total} running: ${Object.entries(count).map(([t, n]) => `${n} ${t}`).join(', ')}`,
    '', 'REACH', ...order.map(reachLine), ...notes.map((n) => `  ${n}`),
  ];
}
