#!/usr/bin/env bash
# Order snapshots and selection records share a lock only while local state is read or written.

tool_order_paths() {
  TOOL_ORDER_HOME="${AI_CORE_HOME:-$HOME}/.ai-core"
  TOOL_ORDER_FILE="$TOOL_ORDER_HOME/tool-order.json"
  TOOL_ORDER_DECISIONS="$TOOL_ORDER_HOME/phase-model.jsonl"
  TOOL_ORDER_LOCK="$TOOL_ORDER_HOME/tool-order.lock"
}

tool_order_error() { printf 'error: %s\n' "$*" >&2; return 2; }

tool_order_lock() {
  local n=0
  mkdir -p "$TOOL_ORDER_HOME" || { tool_order_error "cannot create $TOOL_ORDER_HOME"; return 2; }
  # The shell creates the lock file exclusively itself: the mkdir of some coreutils builds succeeds for two callers racing.
  until ( set -C; : > "$TOOL_ORDER_LOCK" ) 2>/dev/null; do
    [ -w "$TOOL_ORDER_HOME" ] || { tool_order_error "cannot create $TOOL_ORDER_LOCK"; return 2; }
    n=$((n + 1))
    [ "$n" -lt 100 ] || { tool_order_error "cannot lock $TOOL_ORDER_LOCK after 10 seconds"; return 2; }
    sleep 0.1
  done
}

tool_order_unlock() {
  rm "$TOOL_ORDER_LOCK" || { tool_order_error "cannot release $TOOL_ORDER_LOCK"; return 2; }
}

tool_order_read() {
  if [ ! -e "$TOOL_ORDER_FILE" ] && [ ! -L "$TOOL_ORDER_FILE" ]; then printf 'null\n'; return 0; fi
  local state
  state="$(jq -ce -s '
    def order: type == "object" and (.generation | type == "number" and . > 0 and floor == .)
      and (.time | type == "number" and . > 0)
      and (.tools | type == "array" and length == (unique | length)
        and all(. == "codex" or . == "agy" or . == "claude"));
    if length == 1 and (.[0] | .version == 1 and (.orders | type == "array" and length > 0 and all(order))
      and ([range(0; .orders | length) as $i | .orders[$i].generation == ($i + 1)
        and ($i == 0 or .orders[$i].time >= .orders[$i - 1].time)] | all))
    then .[0] else error("malformed order history") end' "$TOOL_ORDER_FILE" 2>&1)" \
    || { tool_order_error "cannot read $TOOL_ORDER_FILE: $state"; return 2; }
  printf '%s\n' "$state"
}

tool_order_snapshot() {
  local state
  state="$(tool_order_read)" || return 2
  jq -c 'if . == null or (.orders[-1].tools | length) == 0 then null else .orders[-1] end' <<< "$state"
}

tool_order_show() {
  local state
  state="$(tool_order_read)" || return 2
  jq -r 'def when: "\(.time) (\(.time | floor | todateiso8601)); generation \(.generation)";
    if . == null then "tool order: not set; native-tool selection"
    elif (.orders[-1].tools | length) == 0 then "tool order: not set; native-tool selection\ncleared at: \(.orders[-1] | when)"
    else .orders[-1] | "tool order: \(.tools | join(","))\nset at: \(when)" end' <<< "$state"
}

tool_order_save() (
  local state temporary=""
  tool_order_lock || return 2
  trap 'rc=$?; [ -z "$temporary" ] || rm -f "$temporary"; tool_order_unlock || rc=2; exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  state="$(tool_order_read)" || return 2
  temporary="$(mktemp "$TOOL_ORDER_HOME/tool-order.XXXXXXXX")" || { tool_order_error 'cannot prepare order replacement'; return 2; }
  jq -cn --argjson old "$state" --arg tools "$1" '
    ($old // {version:1,orders:[]}) | .orders += [{generation:((.orders | length) + 1),time:now,tools:($tools | split(","))}]' > "$temporary" \
    && mv "$temporary" "$TOOL_ORDER_FILE" || { tool_order_error "cannot replace $TOOL_ORDER_FILE"; return 2; }
)

tool_order_record() (
  local record="$1" current expected changed=0
  tool_order_lock || return 2
  trap 'rc=$?; tool_order_unlock || rc=2; exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -e "$TOOL_ORDER_DECISIONS" ] || [ -L "$TOOL_ORDER_DECISIONS" ]; then
    jq -e -s 'all(type == "object" and .version == 1 and (.time | type == "number") and (.reasons | type == "array"))' "$TOOL_ORDER_DECISIONS" >/dev/null \
      || { tool_order_error "cannot read $TOOL_ORDER_DECISIONS"; return 2; }
  fi
  if ! current="$(tool_order_snapshot)"; then
    [ "$(jq -r '.selected == null and (.refusal | length > 0)' <<< "$record")" = true ] || return 2
    current=null
  fi
  expected="$(jq -c '.order' <<< "$record")" || return 2
  if [ "$current" != "$expected" ]; then
    record="$(jq -c '.selected=null | .refusal="order changed during selection; select again"' <<< "$record")" || return 2
    changed=1
  fi
  printf '%s\n' "$record" >> "$TOOL_ORDER_DECISIONS" \
    || { tool_order_error "cannot append $TOOL_ORDER_DECISIONS"; return 2; }
  [ "$changed" -eq 0 ] || { tool_order_error 'order changed during selection; select again'; return 2; }
)

phase_model_base() { printf '%s\n' "$1" | sed -E 's/^(claude|codex|agy)://; s/-(low|medium|high|xhigh|max)$//'; }

# phase_model_tuples <tool> <phase> <table>: every row of the tool for the phase, whatever its class, as
# class<TAB>model<TAB>effort; a row that routes to another tool (a model with a colon) names no tuple of this one.
phase_model_tuples() {
  awk -F'\t' -v tool="$1" -v phase="$2" '
    !/^#/ && NF && $1 == tool && $2 == phase && $4 !~ /:/ { print $3 "\t" $4 "\t" $5 }
  ' "$3"
}

# phase_model_setup <setup file> <class> <table>: the entries of the planner's Setup that the table allows for this class,
# one a line as phase<TAB>tool<TAB>model<TAB>effort, or the reason it is refused on stderr and status 1. The whole object is read before
# any quota is. An entry is a tuple of its own tool: for build and review any the tool's rows name for the phase, for
# a high-risk package exactly its high-risk row; for ui-test exactly its row of the class; and the tool has to run the
# class at all, which its build row for the class says. Its budget is 1.5 times its estimate, rounded up, within the
# ceiling of the phase.
phase_model_setup() {
  local file="$1" class="$2" table="$3" entries phase tool model effort row rows
  [ -f "$file" ] && [ -r "$file" ] || { echo "the setup file $file cannot be read" >&2; return 1; }
  # Read as one array, because an empty file or a second value would otherwise pass as no entry or as a second Setup
  entries="$(jq -s -r '
    def ceiling($phase; $tool): if $phase == "build" then (if $tool == "codex" then 250000 else 300000 end) elif $phase == "review" then 150000 else 100000 end;
    def whole: type == "number" and . == floor and . > 0;
    def text: type == "string" and test("^[^[:space:]]+$");
    if length != 1 then error("it holds \(length) JSON values, not one object") else .[0] end
    | if type != "object" then error("it is not a JSON object") else . end
    | [ to_entries[] | .key as $phase
    | if ($phase | IN("build", "review", "ui-test") | not) then error("it names the phase \($phase), which is none of build, review and ui-test") else . end
    | (.value | if type != "object" then error("\($phase) is not an object of tools") else . end) | to_entries[] | .key as $tool
    | if ($tool | IN("claude", "codex", "agy") | not) then error("\($phase) names the tool \($tool), which is none of claude, codex and agy") else . end
    | .value as $e
    | if ($e | type) != "object" or ($e | keys) != ["budget_tokens", "effort", "estimate_tokens", "model", "reason"]
      then error("\($phase) \($tool) must hold exactly model, effort, estimate_tokens, budget_tokens and reason") else . end
    | if ($e.model | text | not) or ($e.effort | text | not) then error("\($phase) \($tool): model and effort are words with no space") else . end
    | if ($e.reason | type) != "string" or ($e.reason | test("^\\s*$")) then error("\($phase) \($tool) gives no reason") else . end
    | if ($e.estimate_tokens | whole | not) or ($e.budget_tokens | whole | not) then error("\($phase) \($tool): estimate_tokens and budget_tokens are positive whole numbers") else . end
    | if $e.budget_tokens != ($e.estimate_tokens * 1.5 | ceil) then error("\($phase) \($tool): budget_tokens \($e.budget_tokens) is not 1.5 times estimate_tokens \($e.estimate_tokens), rounded up") else . end
    | if $e.budget_tokens > ceiling($phase; $tool) then error("\($phase) \($tool): budget_tokens \($e.budget_tokens) is above the \(ceiling($phase; $tool)) of the phase; a package that needs more is cut again") else . end
    | "\($phase)\t\($tool)\t\($e.model)\t\($e.effort)" ] | .[]' "$file" 2>&1)" \
    || { echo "the setup file $file is refused: $(sed -E 's/^jq: (error \(at .*:[0-9]+\): )?//' <<< "$entries")" >&2; return 1; }
  while IFS=$'\t' read -r phase tool model effort; do
    [ -n "$phase" ] || continue
    row="$(phase_model_row "$tool" build "$class" "$table")" || return 1
    [ -n "$row" ] || { echo "the setup entry $phase $tool is refused: $tool has no build row for $class, so it does not run that class" >&2; return 1; }
    case "$phase:$class" in
      ui-test:*|*:high-risk)
        row="$(phase_model_row "$tool" "$phase" "$class" "$table")" || return 1
        [ -n "$row" ] || { echo "the setup entry $phase $tool is refused: the table has no $phase row of $tool for $class" >&2; return 1; }
        [ "$(cut -f4,5 <<< "$row")" = "$(printf '%s\t%s' "$model" "$effort")" ] \
          || { echo "the setup entry $phase $tool is refused: for $class it is the row of the table, $(cut -f4 <<< "$row") $(cut -f5 <<< "$row"), not $model $effort" >&2; return 1; } ;;
      *)
        rows="$(phase_model_tuples "$tool" "$phase" "$table")"
        awk -F'\t' -v model="$model" -v effort="$effort" '$2 == model && $3 == effort { found = 1 } END { exit !found }' <<< "$rows" \
          || { echo "the setup entry $phase $tool is refused: $model $effort is no tuple of $tool for $phase in the table" >&2; return 1; } ;;
    esac
  done <<< "$entries"
  printf '%s\n' "$entries"
}

# phase_model_rows <tool> <phase> <class> <table>: the rows of the tool for the phase in table order, the rows of the exact
# class, else the rows of `*`; two equal rows are refused as ambiguous.
phase_model_rows() {
  awk -F'\t' -v tool="$1" -v phase="$2" -v class="$3" '
    !/^#/ && NF { if (NF != 5 || $4 !~ /^[^[:space:]]+$/ || $5 !~ /^[^[:space:]]+$/) { print "malformed models.tsv row " NR > "/dev/stderr"; exit 2 }
      if ($1 == tool && $2 == phase && ($3 == class || $3 == "*")) {
        if ($3 == class) { if (exactSeen[$0]++) twice = 1; exact[++exactCount] = $0 }
        else { if (wildSeen[$0]++) wildTwice = 1; wild[++wildCount] = $0 }
      }
    }
    END { if ((exactCount && twice) || (!exactCount && wildTwice)) { print "ambiguous models.tsv rows" > "/dev/stderr"; exit 2 }
      if (exactCount) for (i = 1; i <= exactCount; i++) print exact[i]
      else for (i = 1; i <= wildCount; i++) print wild[i]
    }
  ' "$4"
}

# phase_model_row <tool> <phase> <class> <table>: the first of those rows.
phase_model_row() {
  local rows
  rows="$(phase_model_rows "$@")" || return $?
  [ -z "$rows" ] || printf '%s\n' "${rows%%$'\n'*}"
}

tool_order_audit() {
  tool_order_paths
  command -v node >/dev/null 2>&1 || { tool_order_error 'tool-order audit read failure: node is not on the PATH'; return 2; }
  node --input-type=module - "$TOOL_ORDER_HOME" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
const home = process.argv[2];
const tools = ['codex', 'agy', 'claude'];
const positive = n => typeof n === 'number' && Number.isFinite(n) && n > 0;
const text = s => typeof s === 'string' && s.length > 0;
const base = s => s.replace(/^(claude|codex|agy):/, '').replace(/-(low|medium|high|xhigh|max)$/, '');
const effective = t => [base(t.model), t.effort === '-' ? /-(low|medium|high|xhigh|max)$/.exec(t.model)?.[1] || '-' : t.effort];
const tuple = t => t && tools.includes(t.tool) && text(t.model) && text(t.effort);
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const exists = p => { try { fs.lstatSync(p); return true; } catch (e) { if (e.code === 'ENOENT') return false; throw e; } };
const read = p => fs.readFileSync(p, 'utf8');
const lines = s => s === '' ? [] : s.replace(/\n$/, '').split('\n');
const jsonLines = (s, label) => lines(s).map((line, i) => {
  try { return JSON.parse(line); } catch { throw Error(`${label}:${i + 1}: malformed JSON line`); }
});
const canonical = p => fs.realpathSync(p);
function projectOf(p) {
  p = canonical(p);
  let common;
  try { common = execFileSync('git', ['-C', p, 'rev-parse', '--git-common-dir'], {encoding:'utf8', stdio:['ignore', 'pipe', 'pipe']}).trim(); }
  catch (e) { if (e.status === 128) return p; throw e; }
  return canonical(path.dirname(path.resolve(p, common, '..')));
}
function snapshot() {
  if (!exists(home)) return {orders:[], decisions:[]};
  const lock = path.join(home, 'tool-order.lock');
  const deadline = Date.now() + 10000;
  while (true) {
    try { fs.closeSync(fs.openSync(lock, 'wx')); break; }
    catch (e) {
      if (e.code !== 'EEXIST') throw Error(`cannot lock ${lock}: ${e.message}`);
      if (Date.now() >= deadline) throw Error(`cannot lock ${lock} after 10 seconds`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    }
  }
  try {
    const file = path.join(home, 'tool-order.json');
    const state = exists(file) ? JSON.parse(read(file)) : null;
    if (state !== null && (state.version !== 1 || !Array.isArray(state.orders) || !state.orders.length || state.orders.some((o, i) =>
      o.generation !== i + 1 || !positive(o.time) || (i && o.time < state.orders[i - 1].time) ||
      !Array.isArray(o.tools) || new Set(o.tools).size !== o.tools.length || o.tools.some(t => !tools.includes(t))))) throw Error(`malformed ${file}`);
    const log = path.join(home, 'phase-model.jsonl');
    const decisions = exists(log) ? jsonLines(read(log), log) : [];
    for (const d of decisions) {
      if (d.version !== 1 || !positive(d.time) || !text(d.project) || !text(d.phase) || !text(d.class) || typeof d.writer !== 'string' ||
        !Array.isArray(d.reasons) || (!tuple(d.selected) && d.selected !== null) || typeof d.refusal !== 'string') throw Error(`malformed selection in ${log}`);
      // A project folder can be gone since its selection: that selection then matches no start.
      if (!path.isAbsolute(d.project)) throw Error(`malformed selection in ${log}`);
      if (d.order !== null && !state?.orders.some(o => equal(o, d.order))) throw Error(`selection has no order snapshot in ${file}`);
    }
    return {orders:state?.orders || [], decisions};
  } finally { fs.unlinkSync(lock); }
}
function audit() {
  const {orders, decisions} = snapshot(), order = orders.at(-1);
  if (!order || !order.tools.length) {
    console.log('tool order: not set; native-tool selection');
    if (order) console.log(`cleared at: ${order.time} (${new Date(order.time * 1000).toISOString()}); generation ${order.generation}`);
    console.log('phase starts: no policy set time; no violations assessed');
    return;
  }
  console.log(`tool order: ${order.tools.join(',')}`);
  console.log(`set at: ${order.time} (${new Date(order.time * 1000).toISOString()}); generation ${order.generation}`);
  const dir = path.join(home, 'sessions'), names = new Map(), claims = new Map();
  const parseName = name => /^(plan-check|re-plan|ui-test|keeper|plan|build|review|[pirt])(\d+)-(.+)-([a-z]+)-\d+k-[0-9a-f]{5}$/.exec(name);
  const entry = name => {
    if (!parseName(name)) return null;
    if (!names.has(name)) names.set(name, {name, observations:[], native:new Map(), problems:[], artifacts:[]});
    return names.get(name);
  };
  for (const file of exists(dir) ? fs.readdirSync(dir) : []) {
    const claim = /^l(\d+)\.block$/.exec(file);
    if (claim) {
      const key = Number(claim[1]), group = claims.get(key) || [];
      group.push(path.join(dir, file)); claims.set(key, group); continue;
    }
    const found = /^((?:plan-check|re-plan|ui-test|keeper|plan|build|review|[pirt])\d+-.+-[a-z]+-\d+k-[0-9a-f]{5})(?:\.|$)/.exec(file);
    if (!found) continue;
    const e = entry(found[1]); e.artifacts.push(file);
    if (file === `${e.name}.start.jsonl`) {
      try {
        e.observations = jsonLines(read(path.join(dir, file)), file);
        if (e.observations.some(o => !o || typeof o !== 'object' || Array.isArray(o))) e.problems.push('malformed launch observation');
        e.observations = e.observations.filter(o => o && typeof o === 'object' && !Array.isArray(o));
        if (!e.observations.length) e.problems.push('empty launch observations');
      } catch (err) { e.problems.push(err.message); }
    }
  }
  const native = (name, tool, id, evidence) => {
    const e = entry(name); if (!e) return;
    const list = e.native.get(tool) || [];
    list.push({...evidence, id}); e.native.set(tool, list);
  };
  for (const [tool, registry] of [['codex', 'codex-sessions.tsv'], ['agy', 'agy-conversations.tsv']]) {
    const file = path.join(home, registry);
    for (const line of exists(file) ? lines(read(file)) : []) {
      const [name, id, extra] = line.split('\t');
      if (tool === 'agy' && name.startsWith('agy-')) continue;
      const e = entry(name); if (!e) continue;
      if (!text(id) || extra !== undefined) { e.problems.push(`malformed ${registry} line`); continue; }
      try {
        const output = read(path.join(dir, `${name}.out`));
        let events;
        try { events = [JSON.parse(output)]; } catch { events = jsonLines(output, `${name}.out`); }
        const ids = [...new Set(events.flatMap(o => tool === 'codex' ? (o.type === 'thread.started' && text(o.thread_id) ? [o.thread_id] : []) : (text(o.conversation_id) ? [o.conversation_id] : [])))];
        if (ids.length !== 1 || ids[0] !== id) e.problems.push(`${tool} registry/output identity conflict`);
        else native(name, tool, id, {});
      } catch (err) { e.problems.push(`${tool} output cannot be read: ${err.message}`); }
    }
  }
  // claude agents --json can exit 0 with an empty or cut-off answer, so an answer that is no JSON is read again
  const readAgents = () => {
    for (let read = 1; ; read++) {
      const answer = execFileSync('claude', ['agents', '--json'], {encoding:'utf8', stdio:['ignore', 'pipe', 'pipe'], timeout:10000, maxBuffer:16 * 1024 * 1024});
      try { return JSON.parse(answer); }
      catch (err) { if (read === 3) { err.message += ' (after 3 reads)'; throw err; } }
    }
  };
  let agents, nativeFailure = '';
  try {
    agents = readAgents();
    if (!Array.isArray(agents)) throw Error('not a list');
  } catch (err) {
    agents = [];
    const claudeStarts = [...names.values()].filter(e => e.observations.some(o => o.tool === 'claude'));
    // A machine without Claude Code has no Claude session to list; only a recorded Claude start needs the list.
    if (err.code !== 'ENOENT' || claudeStarts.length) {
      nativeFailure = `claude agents --json failed: ${err.message}`;
      for (const e of claudeStarts) e.problems.push(`claude agents --json failed: ${err.message}`);
    }
  }
  for (const a of agents) if (entry(a.name)) {
    if (!text(a.sessionId) || !text(a.cwd)) entry(a.name).problems.push('Claude native identity or cwd missing');
    else native(a.name, 'claude', a.sessionId, a);
  }
  const nativeNames = new Map();
  for (const e of names.values()) for (const [tool, list] of e.native) for (const n of list) {
    const key = `${tool}\t${n.id}`, group = nativeNames.get(key) || new Set();
    group.add(e.name); nativeNames.set(key, group);
  }

  const starts = [], resumes = [], noStarts = [], unknown = [], counts = Object.fromEntries(tools.map(t => [t, new Set()]));
  let oldNamesArtifactsOnly = 0;
  for (const e of names.values()) {
    const match = parseName(e.name), number = Number(match[2]);
    let project, claimProblem = '';
    try {
      if (!Number.isSafeInteger(number) || number < 10001 || number % 10000 === 0 || String(number) !== match[2]) throw Error('invalid phase number');
      const files = claims.get(Math.floor(number / 10000) * 10000) || [];
      if (files.length !== 1) throw Error(files.length ? 'non-unique block claims' : 'missing block claim');
      const rows = lines(read(files[0])), claim = rows.length === 1 && /^(.*\S)[\t ]+(claude|codex|agy)$/.exec(rows[0]);
      if (!claim) throw Error('malformed block claim');
      project = projectOf(claim[1]);
    } catch (err) { claimProblem = err.message; }
    for (const [tool, list] of e.native) if (new Set(list.map(n => n.id)).size !== 1) e.problems.push(`several ${tool} native identities under one name`);
    const observations = e.observations;
    for (const o of observations) {
      if (o.version !== 1 || !['attempt', 'native'].includes(o.kind) || !['start', 'resume'].includes(o.operation) || !tuple(o) || !positive(o.invoked) ||
        (o.kind === 'native' && (!positive(o.observed) || o.observed < o.invoked || !text(o.nativeIdentity)))) e.problems.push('malformed launch observation');
    }
    const confirmed = observations.filter(o => o.kind === 'native' && tuple(o) && positive(o.invoked) && positive(o.observed) && text(o.nativeIdentity));
    if (!confirmed.length) {
      if (e.native.size || e.problems.length || (observations.length && ['ui-test','t'].includes(match[1]))) unknown.push(`${e.name}: ${e.problems.join('; ') || (e.native.size ? 'missing launch timing; native start time unknown' : 'UI-test has no usable native identity')}`);
      else if (!observations.length && /^[pirt]$/.test(match[1])) oldNamesArtifactsOnly++;
      else noStarts.push(`${e.name}: ${observations.length ? 'launch attempt only; no native start' : 'artifacts only; no native start'}`);
      continue;
    }
    const original = new Map();
    for (const o of confirmed) {
      const problems = [...e.problems], natives = e.native.get(o.tool) || [];
      const identity = natives.filter(n => n.id === o.nativeIdentity);
      if (identity.length !== 1) problems.push(`missing or non-unique ${o.tool} native evidence`);
      const attempts = observations.filter(a => a.kind === 'attempt' && a.operation === o.operation && a.invoked === o.invoked && equal([a.tool,a.model,a.effort], [o.tool,o.model,o.effort]));
      if (attempts.length !== 1) problems.push('missing or ambiguous launch attempt');
      if (claimProblem) problems.push(claimProblem);
      if (o.tool === 'claude' && identity.length === 1 && project) {
        try {
          const cwdProject = projectOf(identity[0].cwd);
          if (cwdProject !== project && match[1] !== 'ui-test' && match[1] !== 't') problems.push('Claude cwd conflicts with block claim');
        } catch (err) { problems.push(`Claude cwd cannot be resolved: ${err.message}`); }
      }
      for (const n of identity) {
        const latest = confirmed.filter(x=>x.tool === o.tool && x.nativeIdentity === o.nativeIdentity).at(-1) === o;
        if (latest && text(n.model) && base(n.model) !== base(o.model)) problems.push('native model conflicts with invocation');
        if (latest && text(n.effort) && effective({model:n.model || o.model,effort:n.effort})[1] !== effective(o)[1]) problems.push('native effort conflicts with invocation');
      }
      const idKey = `${o.tool}\t${o.nativeIdentity}`;
      if ((nativeNames.get(idKey)?.size || 0) > 1) problems.push('one native session has several phase names');
      if (o.operation === 'start') {
        if (original.has(idKey)) { problems.push('several original start observations'); original.get(idKey).problems.push('several original start observations'); }
        else original.set(idKey, {o,problems});
      } else if (!original.has(idKey)) problems.push('resume has no original start observation');
      let phase = match[1];
      if (/^[pirt]$/.test(phase)) {
        const allowed = {p:['plan','re-plan','plan-check'],i:['build'],r:['review'],t:['ui-test']}[phase];
        if (!text(o.phase) || !allowed.includes(o.phase)) problems.push('old phase letter has no independent phase evidence');
        else phase = o.phase;
      } else if (o.phase !== undefined && o.phase !== phase) problems.push('phase name conflicts with observation');
      const start = {e,o,problems,project,phase,lower:o.invoked,upper:o.observed};
      if (o.operation === 'start') {
        if (identity.length === 1 && nativeNames.get(idKey)?.size === 1 && positive(start.lower) && start.lower >= order.time) counts[o.tool].add(e.name);
        starts.push(start);
      } else resumes.push(start);
    }
  }
  const examined = [...starts, ...resumes].filter(s => s.upper >= order.time), paired = new Map();
  for (const s of examined) {
    const {o,problems} = s;
    if (s.lower < order.time) problems.push('start interval spans policy set time');
    const key = d => d.project === s.project && d.phase === s.phase && d.selected && equal(effective(d.selected), effective(o));
    const same = decisions.filter(key), prior = same.filter(d => d.time < s.lower).sort((a,b) => b.time - a.time);
    const d = prior[0];
    if (!d) { problems.push('missing matching decision'); continue; }
    s.decision = d;
    if (decisions.some(x=>x.project === s.project && x.phase === s.phase && x.selected === null && x.time > d.time && x.time <= s.upper)) problems.push('a later selection refused; no usable decision');
    if (prior.filter(x => x.time === d.time).length !== 1) problems.push('tied latest decision time');
    if (same.some(x => x.time >= s.lower && x.time <= s.upper)) problems.push('decision boundary inside native start interval');
    if (same.some(x => x !== d && (x.began ?? x.time) <= d.time && x.time >= (d.began ?? d.time))) problems.push('overlapping selections cannot be paired uniquely');
    const identities = new Set(prior.map(x => `${x.class}\t${x.writer}`));
    if (identities.size > 1 && (!text(o.class) || o.writer === undefined)) problems.push('class or writer conflict is unresolved');
    if ((o.class !== undefined && o.class !== d.class) || (o.writer !== undefined && base(o.writer) !== base(d.writer))) problems.push('class or writer conflicts with latest decision');
    if (!d.order) problems.push('decision predates explicit order');
    else if (d.order.generation !== order.generation || orders.some(x => x.generation !== d.order.generation && x.time >= d.time && x.time <= s.upper)) problems.push('order changed between selection and start; select again');
    const uses = paired.get(d) || []; uses.push(s); paired.set(d, uses);
  }
  for (const uses of paired.values()) if (uses.length > 1) for (const s of uses) s.problems.push('one decision has indistinguishable starts or resumes');
  for (let i=0;i<examined.length;i++) for (let j=i+1;j<examined.length;j++) {
    const a=examined[i], b=examined[j];
    if (a.project === b.project && a.phase === b.phase && equal(effective(a.o),effective(b.o)) && a.lower <= b.upper && b.lower <= a.upper) {
      a.problems.push('overlapping native starts cannot be paired uniquely'); b.problems.push('overlapping native starts cannot be paired uniquely');
    }
  }
  let matched = 0, matchedStarts = 0, red = 0;
  for (const s of examined) {
    if (s.problems.length) { unknown.push(`${s.e.name} ${s.o.operation}: ${[...new Set(s.problems)].join('; ')}`); continue; }
    const d=s.decision, actual=d.order.tools.indexOf(s.o.tool), chosen=d.order.tools.indexOf(d.selected.tool);
    if (actual < 0 || chosen < 0) { unknown.push(`${s.e.name}: execution tool absent from decision order`); continue; }
    matched++;
    if (s.o.operation === 'start') matchedStarts++;
    const bad=actual > chosen; if (bad) red++;
    console.log(`${bad ? 'RED' : 'OK'} ${s.e.name} ${s.o.operation}: actual ${s.o.tool} ${s.o.model} ${s.o.effort}; selected ${d.selected.tool} ${d.selected.model} ${d.selected.effort}; quota ${d.reasons.map(r=>`${r.tool} exit ${r.exit}: ${r.reason}`).join('; ')}`);
  }
  for (const message of unknown) console.log(`UNKNOWN ${message}`);
  for (const message of noStarts) console.log(`NO START ${message}`);
  if (oldNamesArtifactsOnly) console.log(`NO START ${oldNamesArtifactsOnly} old single-letter names with artifacts only, no launch observation and no native identity; not listed one by one`);
  console.log(`phase starts since set time: ${tools.map(t=>`${t} ${counts[t].size}`).join(', ')}; matched ${matched}/${examined.length + unknown.filter(x=>!examined.some(s=>x.startsWith(s.e.name))).length} examined observations; matched starts ${matchedStarts}/${examined.filter(s=>s.o.operation === 'start').length}; red ${red}; unknown ${unknown.length}; no start ${noStarts.length + oldNamesArtifactsOnly}; resumes ${examined.filter(s=>s.o.operation === 'resume').length} (not counted again)`);
  if (nativeFailure) { console.error(`error: tool-order audit read failure: ${nativeFailure}`); process.exitCode = 2; }
}
try { audit(); }
catch (err) { console.error(`error: tool-order audit read failure: ${err.message}`); process.exitCode = 2; }
JS
}
