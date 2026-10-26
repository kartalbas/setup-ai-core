#!/usr/bin/env bash
# Execute the saved Codex launch with a stand-in and refute stale routing instructions.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export HOME="$WORK/home" AI_CORE_HOME="$WORK/core"
mkdir -p "$HOME" "$AI_CORE_HOME"
# The checker reads a source tree, so each single-sentence regression can be planted in a copy.
cat > "$WORK/check.mjs" <<'JS'
import fs from 'node:fs';
const root=process.argv[2], read=p=>fs.readFileSync(root+'/'+p,'utf8').replace(/^# ?/gm,'').replace(/\s+/g,' ');
const contains=(p,s)=>{if(!read(p).includes(s))throw Error(p+': missing '+s)};
const base='skills/person-in-charge/';
contains(base+'references/codex.md','including Claude Code');
contains(base+'references/claude.md','reads `references/codex.md`');
contains(base+'SKILL.md',"order takes precedence and survives restarts and init");
contains(base+'SKILL.md',"With no saved order it keeps native-tool selection");
contains(base+'SKILL.md',"Successful stdout is exactly `TOOL MODEL EFFORT`");
contains(base+'SKILL.md',"selected tool's phase budget");
contains(base+'references/codex.md','ai-core usage --tool codex');
contains(base+'references/codex.md','Exit 2');
contains(base+'references/codex.md','/dev/null');
contains(base+'references/codex.md','codex-sessions.tsv');
contains(base+'references/codex.md','last `agent_message`');
contains(base+'references/codex.md','--file ~/.ai-core/sessions/<session name>.out');
contains(base+'references/codex.md','sandbox_workspace_write.writable_roots=');
contains(base+'references/codex.md','as percent left against `USAGE_STOP_AT` as percent used');
contains(base+'references/claude.md','shown as percent used, with their reset times');
contains(base+'references/agy.md','`phase-model` calls `ai-core usage --tool agy --model MODEL`');
contains(base+'references/agy.md','shows it as percent left, against `USAGE_STOP_AT` as percent used');
contains(base+'references/agy.md','do not start or fall back to another tool');
contains(base+'references/agy.md','holds the conversation id only once the run has ended');
contains('skills/helper/SKILL.md','once that run has ended; the output holds it only then');
if(read('skills/helper/SKILL.md').includes('Take the id from'))throw Error('helper conversation id claim is stale');
if(read(base+'references/agy.md').includes('stands in that first answer'))throw Error('agy conversation id claim is stale');
if(read(base+'references/agy.md').includes('no command the harness reads'))throw Error('agy quota claim is stale');
if(read(base+'references/codex.md').includes('keeps the folders of its start'))throw Error('false resume folder claim');
const reference=fs.readFileSync(root+'/'+base+'references/codex.md','utf8');
const start=reference.split('## Start a phase session')[1].split('## Ask the owner')[0];
if(start.indexOf(': > \"$out\"')<0 || start.indexOf(': > \"$out\"')>start.indexOf('  codex exec'))throw Error('output must exist before watching');

contains('rules/80-working-style-for-agents.md','on its own because a quota ran out');
contains('rules/80-working-style-for-agents.md','every session using that limited account or model');
contains('README.md',"`ai-core tool-order claude` returns to Claude alone");
contains('templates/.ai-core/models.tsv',"Saving an order leaves the model rows unchanged");
contains('README.md','| `tool-order` | `ai-core tool-order [TOOL[,TOOL...]]`');
contains('README.md','| `phase-model` | `ai-core phase-model PHASE CLASS [--written-by MODEL]`');
contains('README.md','Without `--tool`, also reports the saved order, set time, per-tool start counts');
contains(base+'SKILL.md','order <saved order or not set> | selected <TOOL MODEL EFFORT>');
contains(base+'SKILL.md','ai-core phase-model plan-check <class> --written-by <actual plan or re-plan model>');
contains(base+'SKILL.md','ai-core phase-model review <class> --written-by <model that built the repair>');
contains(base+'SKILL.md','A week it names as reaching the limit is watched by whoever holds the account');

contains(base+'briefs/build.md',"You build it yourself, in your own tool");
contains(base+'briefs/plan.md',"Then walk each promise as the person meets it on that environment");
contains(base+'briefs/plan.md',"so the UI test proves it instead of finding it");
contains(base+'briefs/plan.md',"A defect you read in a span of the package joins the package as a criterion of the issue it touches");
contains(base+'briefs/plan-check.md',"Each gap names the issue of the package it belongs to");
contains(base+'briefs/plan-check.md',"A gap never becomes an issue of its own");
contains(base+'briefs/review.md',"A defect you meet outside the diff but in the package's files or contracts you repair too");
contains(base+'briefs/review.md',"you file no issue: the project's issue keeper files it into what exists");
contains(base+'briefs/review.md',"goes under NOTES as `KEEPER:`, never into FINDINGS");
contains(base+'briefs/plan.md',"and you file no issue: the project's issue keeper files it into what exists");
contains(base+'briefs/plan-check.md',"the project's issue keeper files it into what exists");
contains(base+'briefs/build.md',"You file no issue, because the project's issue keeper files into what exists");
contains(base+'briefs/ui-test.md',"and the project's issue keeper files it into what exists");
contains(base+'briefs/clearing.md',"for the project's issue keeper, which files it into what exists");
contains(base+'briefs/keeper.md',"Never file a new issue or a new epic without the owner's yes");
contains(base+'SKILL.md',"One session per project files its issues: the issue keeper, the model-table phase `keeper`");
contains(base+'SKILL.md',"ai-core phase-model keeper normal-hard");
contains('rules/80-working-style-for-agents.md',"a session that finds an issue hands it to the project's issue keeper, which files it into what exists");
contains('README.md',"One session per project files its issues, the issue keeper, the `keeper` row of `models.tsv`");
for(const tool of ['claude','codex','agy'])if(!read('templates/.ai-core/models.tsv').includes(' '+tool+' keeper * '))throw Error('models.tsv: no keeper row of '+tool);
contains(base+'SKILL.md',"goes back to `implementing`, with the SEEN text as a new acceptance criterion on that same issue");
contains(base+'SKILL.md',"A `type:bug` issue opens only for what the card's own criteria do not cover");
contains(base+'briefs/ui-test.md',"A FAIL of a card's own promise is that card's FAIL, not a new defect.");
contains(base+'briefs/coordinator.md',"One defect is one issue, in the repository that owns it");
contains(base+'briefs/clearing.md',"→ testing, unless a UI test said FAIL after its `Landed on` record");
contains(base+'briefs/clearing.md',"landed, a UI test said FAIL → a build session (briefs/build.md)");
contains(base+'SKILL.md',"landed work goes to `testing` unless a UI test said FAIL after its landing");
const handOver=['SKILL.md','briefs/plan.md','briefs/plan-check.md','briefs/review.md','briefs/ui-test.md','briefs/coordinator.md','briefs/clearing.md','briefs/build.md','briefs/keeper.md'];
for (const file of handOver)
  for (const stale of ['Left out:','`OUTSIDE:`'])
    if(read(base+file).includes(stale))throw Error(file+': the hand-over has two words: '+stale);
const files=['SKILL.md','briefs/plan.md','briefs/plan-check.md','briefs/review.md','briefs/ui-test.md','briefs/coordinator.md','briefs/clearing.md','briefs/build.md'];
for (const file of files)
  for (const stale of ['--found-in','opens one `type:bug`','stays in `testing`'])
    if(read(base+file).includes(stale))throw Error(file+': a failed UI test still opens an issue: '+stale);
JS
node "$WORK/check.mjs" "$ROOT" || fail 'phase routing contract'
cp -R "$ROOT/skills" "$WORK/skills"
mkdir -p "$WORK/rules" "$WORK/templates/.ai-core"
cp "$ROOT/rules/80-working-style-for-agents.md" "$WORK/rules/"
cp "$ROOT/templates/.ai-core/models.tsv" "$WORK/templates/.ai-core/"
cp "$ROOT/README.md" "$WORK/"
for pair in 'references/codex.md|including Claude Code' 'SKILL.md|order takes precedence and survives restarts and init' 'SKILL.md|With no saved order it keeps native-tool selection' 'references/codex.md|last `agent_message`' 'references/codex.md|--file ~/.ai-core/sessions/<session name>.out' 'references/codex.md|sandbox_workspace_write.writable_roots=' 'references/codex.md|as percent left against' 'references/claude.md|shown as percent used, with their reset times' 'references/agy.md|`phase-model` calls' 'references/agy.md|shows it as percent left, against' 'references/agy.md|do not start or fall back to another tool' 'briefs/plan.md|so the UI test proves it instead of finding it' 'briefs/plan.md|joins the package as a criterion of the issue it touches' 'briefs/plan-check.md|A gap never becomes an issue of its own' 'briefs/review.md|you file no issue: the project'"'"'s issue keeper files it into what exists' 'briefs/plan.md|and you file no issue: the project'"'"'s issue keeper files it into what exists' 'briefs/plan-check.md|the project'"'"'s issue keeper files it into what exists' 'briefs/build.md|You file no issue, because the project'"'"'s issue keeper files into what exists' 'briefs/ui-test.md|and the project'"'"'s issue keeper files it into what exists' 'briefs/keeper.md|Never file a new issue or a new epic without the owner'"'"'s yes' 'SKILL.md|ai-core phase-model keeper normal-hard' 'briefs/review.md|never into FINDINGS' 'SKILL.md|goes back to `implementing`' 'briefs/ui-test.md|not a new defect' 'briefs/coordinator.md|One defect is one issue' 'briefs/clearing.md|unless a UI test said FAIL after its `Landed on` record' 'briefs/clearing.md|a build session (briefs/build.md) from the issue' 'SKILL.md|unless a UI test said FAIL after its landing' 'SKILL.md|is watched by whoever holds the account'; do
  file="${pair%%|*}"; phrase="${pair#*|}"
  FILE="$WORK/skills/person-in-charge/$file" PHRASE="$phrase" node -e 'const fs=require("fs"),p=process.env.FILE,s=fs.readFileSync(p,"utf8");fs.writeFileSync(p,s.replace(new RegExp(process.env.PHRASE.split(/\s+/).map(x=>x.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")).join("\\s+")),"stale instruction"))'
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "stale instruction escaped: $phrase"; fi
  cp "$ROOT/skills/person-in-charge/$file" "$WORK/skills/person-in-charge/$file"
done
# A stale sentence planted in any file of the check goes red; the restored tree stays green.
for file in SKILL.md briefs/plan.md briefs/plan-check.md briefs/review.md briefs/ui-test.md briefs/coordinator.md briefs/clearing.md briefs/build.md; do
  for stale in '--found-in' 'opens one `type:bug`' 'stays in `testing`'; do
    printf '\n%s\n' "$stale" >> "$WORK/skills/person-in-charge/$file"
    if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "stale sentence escaped in $file: $stale"; fi
    cp "$ROOT/skills/person-in-charge/$file" "$WORK/skills/person-in-charge/$file"
  done
done
# Either old hand-over word planted in a brief goes red; so does a table without a keeper row and a tree without the keeper brief.
for file in SKILL.md briefs/plan.md briefs/plan-check.md briefs/review.md briefs/ui-test.md briefs/coordinator.md briefs/clearing.md briefs/build.md briefs/keeper.md; do
  for stale in 'Left out:' '`OUTSIDE:`'; do
    printf '\n%s\n' "$stale" >> "$WORK/skills/person-in-charge/$file"
    if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "old hand-over word escaped in $file: $stale"; fi
    cp "$ROOT/skills/person-in-charge/$file" "$WORK/skills/person-in-charge/$file"
  done
done
for tool in claude codex agy; do
  grep -v -P "^$tool\tkeeper\t" "$ROOT/templates/.ai-core/models.tsv" > "$WORK/templates/.ai-core/models.tsv"
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "a table without the keeper row of $tool passed"; fi
  cp "$ROOT/templates/.ai-core/models.tsv" "$WORK/templates/.ai-core/models.tsv"
done
rm "$WORK/skills/person-in-charge/briefs/keeper.md"
if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail 'a tree without the keeper brief passed'; fi
cp "$ROOT/skills/person-in-charge/briefs/keeper.md" "$WORK/skills/person-in-charge/briefs/keeper.md"
printf '\nThe conversation id stands in that first answer.\n' >> "$WORK/skills/person-in-charge/references/agy.md"
if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail 'stale agy conversation id claim escaped'; fi
cp "$ROOT/skills/person-in-charge/references/agy.md" "$WORK/skills/person-in-charge/references/agy.md"
printf '\nTake the id from the first call.\n' >> "$WORK/skills/helper/SKILL.md"
if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail 'stale helper conversation id claim escaped'; fi
cp "$ROOT/skills/helper/SKILL.md" "$WORK/skills/helper/SKILL.md"
printf '\nagy has no command the harness reads for its quota\n' >> "$WORK/skills/person-in-charge/references/agy.md"
if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail 'stale agy quota claim escaped'; fi
cp "$ROOT/skills/person-in-charge/references/agy.md" "$WORK/skills/person-in-charge/references/agy.md"
for command in tool-order phase-model usage; do
  awk -v word="$command" 'index($0, "| `" word "` |") != 1 {print}' "$ROOT/README.md" > "$WORK/README.md"
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "unchecked README row: $command"; fi
  cp "$ROOT/README.md" "$WORK/README.md"
done
node "$WORK/check.mjs" "$WORK" || fail 'restored tree must stay green'
node --input-type=module - "$ROOT" "$WORK" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const [root,work]=process.argv.slice(2), bin=path.join(work,'bin'), captures=path.join(work,'captures'), native=path.join(work,'native.json');
fs.mkdirSync(bin);fs.mkdirSync(captures);
const commands={};
for(const tool of ['codex','agy','claude']) {
  const ref=fs.readFileSync(path.join(root,`skills/person-in-charge/references/${tool}.md`),'utf8');
  commands[tool]=ref.match(/```bash\n([\s\S]*?)\n```/)[1];
}
fs.writeFileSync(path.join(bin,'ai-core'),`#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$CAPTURES/selector"
[ "$1" = phase-model ] || exit 7
[ "\${SELECTOR_RC:-0}" = 0 ] || exit "$SELECTOR_RC"
printf '%s\\n' "$SELECTION"
`);
const planted=`#!/usr/bin/env bash
set -euo pipefail
tool="\${0##*/}"
if [ "$tool" = claude ] && [ "\${1:-}" = agents ]; then cat "$NATIVE"; exit 0; fi
jq -cn --arg tool "$tool" --args '{tool:$tool,args:$ARGS.positional}' -- "$@" >> "$CAPTURES/calls"
id="$tool-identity"
if [ "$tool" = claude ]; then
  name="$SESSION"
  jq -cn --arg name "$name" --arg id "$id" --arg cwd "$PROJECT" '[{name:$name,sessionId:$id,id:"short-id",cwd:$cwd,status:"idle",state:"done"}]' > "$NATIVE"
  printf '%s\\n' "$id"
elif [ "$tool" = codex ]; then
  [ -z "$(cat)" ] || exit 9
  [ -z "\${CODEX_DELAY:-}" ] || sleep "$CODEX_DELAY"
  printf '%s\\n' '{"type":"thread.started","thread_id":"codex-identity"}' '{"type":"item.completed","item":{"type":"agent_message","text":"fixture final report"}}' '{"type":"turn.completed"}'
else
  printf '%s\\n' '{"conversation_id":"agy-identity","answer":"fixture final report"}'
fi
`;
for(const tool of ['codex','agy','claude'])fs.writeFileSync(path.join(bin,tool),planted);
for(const file of fs.readdirSync(bin))fs.chmodSync(path.join(bin,file),0o755);
const project=path.join(work,'project folder'), brief=path.join(work,'brief'), added=path.join(work,'added');
fs.mkdirSync(project);fs.mkdirSync(added);fs.writeFileSync(brief,'fixture brief\n');
const codexHome=path.join(work,'codex');fs.mkdirSync(codexHome);
fs.writeFileSync(path.join(codexHome,'ai-core.config.toml'),"[auto_review]\npolicy = '''\nfixture approval policy\n'''\n");
let serial=0, checks=0;
const models={codex:['gpt-6-astra','max'],agy:['claude-opus-5-5-high','-'],claude:['claude-opus-5-5','high']};
function context(tool) {
  fs.writeFileSync(native,'[]');for(const f of ['calls','selector'])fs.writeFileSync(path.join(captures,f),'');
  const [model,effort]=models[tool];
  return {...process.env,PATH:bin+path.delimiter+process.env.PATH,CAPTURES:captures,NATIVE:native,CODEX_HOME:codexHome,PROJECT:project,PHASE:'review',CLASS:'high-risk',WRITER:'writer-model',SESSION:`review${10001+serial++}-fixture-high-250k-abcde`,BRIEF:brief,OPERATION:'start',EXTRA_ROOTS:JSON.stringify([added]),WINDOW:'350000',SELECTION:`${tool} ${model} ${effort}`};
}
const run=(tool,env,code=commands[tool])=>{const file=path.join(work,'launch.sh');fs.writeFileSync(file,code+'\n');const r=spawnSync('bash',[file],{env,cwd:project,encoding:'utf8',timeout:90000});if(r.error)throw r.error;return r;};
const calls=()=>fs.readFileSync(path.join(captures,'calls'),'utf8').trim().split('\n').filter(Boolean).map(l=>JSON.parse(l));
const observations=env=>fs.readFileSync(path.join(env.AI_CORE_HOME,`.ai-core/sessions/${env.SESSION}.start.jsonl`),'utf8').trim().split('\n').map(s=>JSON.parse(s));
const hasPair=(args,flag,value)=>args.some((a,i)=>a===flag && args[i+1]===value);
function verify(tool,env,operation='start') {
  const selected=env.SELECTION.split(' '), actual=calls().at(-1);
  assert.ok(actual,'native CLI must run');assert.equal(actual.tool,selected[0]);
  assert.ok(hasPair(actual.args,tool==='codex'?'-m':'--model',selected[1]),'selected model');
  if(tool==='codex')assert.ok(hasPair(actual.args,'-c',`model_reasoning_effort=${selected[2]}`),'selected effort');
  else if(tool==='claude')assert.ok(hasPair(actual.args,'--effort',selected[2]),'selected effort');
  else assert.ok(!actual.args.includes('--effort'));
  assert.match(fs.readFileSync(path.join(captures,'selector'),'utf8'),/phase-model review high-risk --written-by writer-model/);
  const records=observations(env), last=records.slice(-2);assert.deepEqual(last.map(o=>o.kind),['attempt','native']);
  for(const o of last){assert.equal(o.operation,operation);assert.equal(o.tool,selected[0]);assert.equal(o.model,selected[1]);assert.equal(o.effort,selected[2]);assert.ok(o.observed>=o.invoked);assert.ok(Buffer.byteLength(JSON.stringify(o)+'\n')<4096);}
  assert.equal(last[1].nativeIdentity,`${tool}-identity`);
  if(tool!=='codex' || operation==='start')assert.ok(hasPair(actual.args,'--add-dir',added),'every folder of EXTRA_ROOTS is added');
  if(tool==='claude' && operation==='start')assert.ok(hasPair(actual.args,'--settings','{"autoCompactWindow":350000}'),'the window of the session budget');
  if(operation==='resume'){
    assert.ok(hasPair(actual.args,tool==='agy'?'--conversation':'--resume',env.NATIVE_ID) || (tool==='codex' && actual.args.includes(env.NATIVE_ID)));
    assert.equal(records.filter(o=>o.kind==='native' && o.operation==='start').length,1);
  }
  if(tool==='codex'){
    assert.ok(actual.args.includes('--skip-git-repo-check'));
    if(operation==='start'){assert.ok(hasPair(actual.args,'-p','ai-core'));assert.ok(hasPair(actual.args,'-C',project));assert.ok(hasPair(actual.args,'--add-dir',env.AI_CORE_HOME+'/.ai-core'));}
    else {assert.ok(!actual.args.includes('-p'));const roots=actual.args.find(a=>a.startsWith('sandbox_workspace_write.writable_roots='));assert.deepEqual(JSON.parse(roots.split('=').slice(1).join('=')),[project,env.AI_CORE_HOME+'/.ai-core',added]);for(const setting of ['sandbox_mode="workspace-write"','approval_policy="on-request"','approvals_reviewer="auto_review"','sandbox_workspace_write.network_access=false'])assert.ok(actual.args.includes(setting));assert.ok(actual.args.some(a=>a.includes('fixture approval policy')));}
  }
}
const check=(name,fn)=>{fn();console.log(`ok ${++checks} ${name}`);};
for(const tool of ['codex','agy','claude'])check(`${tool} executable start and resume use fresh selected tuples and retain native evidence`,()=>{
  const env=context(tool);let r=run(tool,env);assert.equal(r.status,0,r.stderr);verify(tool,env);
  env.OPERATION='resume';env.NATIVE_ID=`${tool}-identity`;env.TEXT='continue';
  if(tool==='codex')env.SELECTION='codex gpt-6.1-sol xhigh';if(tool==='agy')env.SELECTION='agy claude-sonnet-5-5-high -';if(tool==='claude')env.SELECTION='claude claude-sonnet-5-5 xhigh';
  r=run(tool,env);assert.equal(r.status,0,r.stderr);verify(tool,env,'resume');
});
for(const tool of ['codex','agy','claude'])check(`${tool} failed selector and failed observation write start nothing`,()=>{
  let env=context(tool);env.SELECTOR_RC='2';assert.equal(run(tool,env).status,2);assert.equal(calls().length,0);
  env=context(tool);fs.mkdirSync(path.join(env.AI_CORE_HOME,`.ai-core/sessions/${env.SESSION}.start.jsonl`));const r=run(tool,env);assert.equal(r.status,2,r.stderr);assert.match(r.stderr,/cannot append/);assert.equal(calls().length,0);
});
check('changed execution tool continues fresh with current brief and no foreign conversation id',()=>{
  const env=context('codex');env.SELECTION='agy claude-opus-5-5-high -';env.OPERATION='resume';env.NATIVE_ID='foreign-codex-thread';env.TEXT='continue';let r=run('codex',env);assert.equal(r.status,2);assert.match(r.stderr,/Continue fresh through references\/agy.md/);assert.equal(calls().length,0);env.OPERATION='start';env.NATIVE_ID='';r=run('agy',env);assert.equal(r.status,0,r.stderr);verify('agy',env);assert.ok(!calls().at(-1).args.includes('foreign-codex-thread'));assert.ok(calls().at(-1).args.includes('fixture brief\n') || calls().at(-1).args.includes('fixture brief'));
});
check('a Claude start without its window starts nothing and records no attempt',()=>{const env=context('claude');delete env.WINDOW;const r=run('claude',env);assert.notEqual(r.status,0);assert.match(r.stderr,/WINDOW/);assert.equal(calls().length,0);assert.equal(fs.existsSync(path.join(env.AI_CORE_HOME,`.ai-core/sessions/${env.SESSION}.start.jsonl`)),false);});
check('an agy UI test runs in its throwaway folder with no folder of the project added',()=>{const env=context('agy'), throwaway=path.join(work,'ui-throwaway');fs.mkdirSync(throwaway,{recursive:true});Object.assign(env,{PHASE:'ui-test',CLASS:'normal-hard',WRITER:'',UI_TEST_DIR:throwaway,SESSION:`ui-test${10001+serial++}-fixture-high-100k-abcde`});let r=run('agy',env);assert.equal(r.status,0,r.stderr);const args=calls().at(-1).args;assert.ok(!args.includes('--add-dir'),JSON.stringify(args));assert.ok(!args.includes(project));delete env.UI_TEST_DIR;env.SESSION=`ui-test${10001+serial++}-fixture-high-100k-abcde`;r=run('agy',env);assert.notEqual(r.status,0);assert.match(r.stderr,/UI_TEST_DIR/);});
check('a still-running Claude conversation cannot resume',()=>{const env=context('claude');env.OPERATION='resume';env.NATIVE_ID='claude-identity';env.TEXT='continue';fs.writeFileSync(native,JSON.stringify([{name:env.SESSION,sessionId:env.NATIVE_ID,status:'busy',state:'working'}]));assert.equal(run('claude',env).status,2);assert.equal(calls().length,0);});
for(const tool of ['codex','agy','claude'])for(const [name,mutate] of [
  ['missing selector',code=>code.replace('selection="$(ai-core phase-model "${args[@]}")" || exit 2',`selection="${tool} ${models[tool].join(' ')}"`)],
  ['missing native observation',code=>code.replace('observe native "$id"','true')],
  ['missing attempt',code=>code.replace('observe attempt','true')],
  ['wrong model',code=>code.replaceAll(tool==='codex'?'-m "$model"':'--model "$model"',tool==='codex'?'-m stale-model':'--model stale-model')]
])check(`${tool} planted ${name} makes the executable check red; restored launch stays green`,()=>{
  const env=context(tool), changed=mutate(commands[tool]);assert.notEqual(changed,commands[tool]);const r=run(tool,env,changed);if(r.status===0)assert.throws(()=>verify(tool,env));else assert.notEqual(r.status,0);
  const clean=context(tool), good=run(tool,clean);assert.equal(good.status,0,good.stderr);verify(tool,clean);
});
for(const [label,mutate] of [
  ['omitted resume model',code=>code.replace('resume "$NATIVE_ID" -m "$model"','resume "$NATIVE_ID"')],
  ['omitted resume effort',code=>code.replace('resume "$NATIVE_ID" -m "$model" -c "model_reasoning_effort=$effort"','resume "$NATIVE_ID" -m "$model"')]
])check(`Codex ${label} is red with an innocent resume`,()=>{
  const env=context('codex');assert.equal(run('codex',env).status,0);env.OPERATION='resume';env.NATIVE_ID='codex-identity';env.TEXT='continue';const code=mutate(commands.codex);assert.notEqual(code,commands.codex);const r=run('codex',env,code);assert.equal(r.status,0,r.stderr);assert.throws(()=>verify('codex',env,'resume'));const clean=context('codex');assert.equal(run('codex',clean).status,0);clean.OPERATION='resume';clean.NATIVE_ID='codex-identity';clean.TEXT='continue';const good=run('codex',clean);assert.equal(good.status,0,good.stderr);verify('codex',clean,'resume');
});
check('Codex finishing between the read of its output and the look at its process is no missing evidence',()=>{
  const slow=path.join(work,'slow-head');fs.mkdirSync(slow);
  fs.writeFileSync(path.join(slow,'head'),`#!/usr/bin/env bash
real="$(PATH="$REAL_PATH" command -v head)"
if [ ! -e "$HEAD_MARK" ]; then : > "$HEAD_MARK"; content="$("$real" "$@")"; sleep 1; printf '%s' "$content"; exit; fi
exec "$real" "$@"
`);fs.chmodSync(path.join(slow,'head'),0o755);
  const env=context('codex');Object.assign(env,{CODEX_DELAY:'0.3',REAL_PATH:env.PATH,HEAD_MARK:path.join(work,'head-mark'),PATH:slow+path.delimiter+env.PATH});
  const racy=commands.codex.replace('alive=1; kill -0 "$pid" 2>/dev/null || alive=0\n','').replace('[ "$alive" = 0 ]','! kill -0 "$pid" 2>/dev/null');assert.notEqual(racy,commands.codex);
  const bad=run('codex',env,racy);assert.equal(bad.status,2);assert.match(bad.stderr,/no native thread evidence/);
  fs.rmSync(env.HEAD_MARK);fs.rmSync(path.join(env.AI_CORE_HOME,`.ai-core/sessions/${env.SESSION}.out`),{force:true});
  fs.writeFileSync(path.join(env.AI_CORE_HOME,`.ai-core/sessions/${env.SESSION}.start.jsonl`),'');
  const good=run('codex',env);assert.equal(good.status,0,good.stderr);verify('codex',env);
});
console.log(`phase launch examples: ${checks} checks passed`);
JS
