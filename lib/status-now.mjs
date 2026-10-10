// What runs now, the default page of `ai-core status`: the board counts and every agent process on
// this machine, with the runs each one started nested under it, and the command that reaches each.
// Only what is measured is shown: the board, the process list, Claude Code's list of its sessions
// and the codex files the processes hold open, as the twins hand them over. Who works on what and
// what comes next is the coordinator's to say, from what it knows; the person-in-charge skill
// builds that table on top.
//
// The process list, one process a line: pid, parent pid, time running ([[dd-]hh:]mm:ss as ps
// writes it, or plain seconds as status.ps1 writes them), the state as ps writes it (empty where
// the system has none) and the command line, a tab between.

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
const HELPER = /\s--chrome-native-host(?:\s|$)|^(?:"?\S*node(?:\.exe)?"?\s+)?"?\S+"?\s+(?:daemon|bg-pty-host|agents)(?:\s|$)/;
// Claude Code keeps spare processes that a background session claims; one that no session has
// claimed is in no list of Claude Code's and carries no session on its command line
const SPARE = /\sbg-spare(?:\s|$)/;
// A worker's name carries its model and effort (the person-in-charge skill names it
// l<n>-<model><version>-<effort>-<context>-<5 hex>), where its command line carries neither
const WORKER_NAME = /^l\d+-([a-z]+(?:\d+(?:\.\d+)?)?)-([a-z]+)-\d+k-[0-9a-f]{5}$/;
// The issue of the worktree a session was started in, <repo>/issue-<n>-<words>: Claude Code keeps
// that folder for good, while a worker given a later package works there by path, so the table
// says "at start"
const WORKTREE = /([^\\/]+)[\\/]issue-(\d+)-[^\\/]*[\\/]?$/;
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

// The command that reaches each agent, by pid, from what its CLI reports and nothing guessed:
// `claude agents --json` names every Claude session with its pid, and a codex process holds its
// rollout-<time>-<uuid>.jsonl open, a line "/proc/<pid>/fd<tab><path>" where the system shows it.
// A running background session is reached with attach: --resume would start a second process
// on the same session.
function reachOf(claudeAgents, rollouts) {
  const reach = new Map(), notes = [], sessions = new Map();
  if (claudeAgents.trim()) {
    let list = null;
    try { list = JSON.parse(claudeAgents); } catch { /* reported below */ }
    if (!Array.isArray(list)) notes.push(`claude agents --json gave no list: ${claudeAgents.trim().split('\n')[0].slice(0, 60)}`);
    for (const a of Array.isArray(list) ? list : []) {
      const command = a.kind === 'background' && a.id ? `claude attach ${a.id}` : a.sessionId ? `claude --resume ${a.sessionId}` : '';
      if (a.pid && command) reach.set(`claude ${a.pid}`, { name: a.name || '', command });
      // Claude Code's own word for a session: busy or idle, and for a background one working,
      // blocked or done; a worker that waits for an answer reads idle blocked
      const state = [a.status, a.state].filter((s) => typeof s === 'string' && s).join(' ');
      if (a.pid) sessions.set(String(a.pid), { name: a.name || '', cwd: a.cwd || '', state });
    }
  }
  for (const line of rollouts) {
    const m = new RegExp(`[\\\\/](\\d+)[\\\\/]fd\\t.*rollout-.*(${UUID})\\.jsonl$`).exec(line);
    if (m) reach.set(`codex ${m[1]}`, { name: '', command: `codex resume ${m[2]}` });
  }
  return { reach, notes, sessions };
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
    const [pid, ppid, age, state, ...args] = line.split('\t');
    if (pid && args.length) procs.set(pid, { pid, ppid, secs: seconds(age), stopped: /^[Tt]/.test(state || ''), args: args.join('\t') });
  }
  const { reach, notes, sessions } = reachOf(claudeAgents, rollouts);
  const agents = new Map();
  for (const p of procs.values()) {
    const tool = TOOLS.find((t) => cli(t).test(p.args) || (t === 'claude' && CLAUDE_BINARY.test(p.args)));
    const idleSpare = tool === 'claude' && SPARE.test(p.args) && !sessions.has(p.pid);
    if (tool && !HELPER.test(p.args) && !idleSpare) agents.set(p.pid, { ...p, tool, session: tool === 'claude' ? sessions.get(p.pid) : undefined });
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
  let stopped = 0;
  const walk = (a, depth) => {
    if (a.stopped) stopped++; else count[a.tool] = (count[a.tool] || 0) + 1;
    order.push(a);
    // The command line wins; where it says nothing, Claude Code's list of its sessions does
    const argName = /\s(?:--resume|-r|--name|-n)[ =]([^\s-]\S*)/.exec(a.args);
    const name = argName ? argName[1] : (a.session && a.session.name) || '';
    const byName = WORKER_NAME.exec(name);
    const argModel = /(?:\s-m|\s--model)[ =](\S+)/.exec(a.args), argEffort = /model_reasoning_effort=(\w+)|--effort[ =](\w+)/.exec(a.args);
    const model = argModel ? argModel[1] : byName ? byName[1] : '';
    const effort = argEffort ? argEffort[1] || argEffort[2] : byName ? byName[2] : '';
    const argIssues = [...new Set(a.args.match(/[\w.-]*#\d+/g) || [])];
    const tree = !argIssues.length && a.session && WORKTREE.exec(a.session.cwd);
    const issues = argIssues.length ? argIssues.slice(0, 3).join(' ') : tree ? `${tree[1]}#${tree[2]} at start` : '';
    const kind = RUN[a.tool].test(a.args) ? (/\sexec\s+resume\b/.test(a.args) ? 'resumed run' : 'run') : 'session';
    rows.push([`${'  '.repeat(depth)}${depth ? '└ ' : ''}${a.tool}${name ? ' ' + name.slice(0, 12) : ''}`, a.pid,
      [model, effort].filter(Boolean).join(' · '),
      a.stopped ? 'stopped' : `${Math.round(a.secs / 60)} min`, (!a.stopped && a.session && a.session.state) || '', issues, kind]);
    for (const c of (children.get(a.pid) || []).sort((x, y) => x.secs - y.secs)) walk(c, depth + 1);
  };
  for (const a of [...agents.values()].filter((x) => !x.owner).sort((x, y) => y.secs - x.secs)) walk(a, 0);

  const counts = cols.map((c) => `${c} ${statuses.filter((s) => s.toLowerCase() === c.toLowerCase()).length}`);
  const total = Object.values(count).reduce((a, b) => a + b, 0);
  const reachLine = (a) => {
    const r = reach.get(`${a.tool} ${a.pid}`);
    return `  ${a.pid.padEnd(8)} ${((r && r.name) || a.tool).padEnd(28)} ${r ? r.command : '—'}`;
  };
  return [
    `${folder.split(/[\\/]/).pop()} · board ${board} · ${when(now)} · ${counts.join(' · ')}`,
    '', 'AGENTS ON THIS MACHINE',
    ...table(['agent', 'pid', 'model', 'running', 'state', 'issues', 'kind'], rows, [22, 8, 26, 9, 12, 22, 11]),
    '', `AGENTS  ${total} running${total ? ': ' + Object.entries(count).map(([t, n]) => `${n} ${t}`).join(', ') : ''}${stopped ? `; ${stopped} stopped` : ''}`,
    '', 'REACH', ...order.map(reachLine), ...notes.map((n) => `  ${n}`),
  ];
}
