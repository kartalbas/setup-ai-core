#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/tool-environment.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AI_CORE_HOME="$WORK/state"
mkdir -p "$HOME" "$AI_CORE_HOME"
node --input-type=module - "$ROOT" "$WORK" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync,spawn} from 'node:child_process';
const [root,work]=process.argv.slice(2), source=path.join(work,'source'), state=path.join(process.env.AI_CORE_HOME,'.ai-core');
for(const d of ['bin','lib','templates/.ai-core'])fs.mkdirSync(path.join(source,d),{recursive:true});
for(const f of ['bin/phase-model.sh','bin/tool-order.sh','lib/tool-order.sh','lib/common.sh','templates/.ai-core/models.tsv'])fs.copyFileSync(path.join(root,f),path.join(source,f));
const quota=path.join(work,'quota');fs.mkdirSync(quota);fs.mkdirSync(state,{recursive:true});
fs.writeFileSync(path.join(source,'bin/usage.sh'),`#!/usr/bin/env bash
tool="$2"
printf '%s\\n' "$*" >> "$QUOTA/$tool.args"
if [ -e "$QUOTA/hold" ]; then touch "$QUOTA/ready"; while [ -e "$QUOTA/hold" ]; do sleep 0.05; done; fi
printf '%s\\n' "$tool quota fixture exit $(cat "$QUOTA/$tool")"
exit "$(cat "$QUOTA/$tool")"
`);
for(const t of ['codex','agy','claude'])fs.writeFileSync(path.join(quota,t),'0');
const project=path.join(work,'project with spaces'), other=path.join(work,'other project');
for(const p of [project,other])fs.mkdirSync(path.join(p,'.ai-core'),{recursive:true});
const env={...process.env,QUOTA:quota};
const run=(args,cwd=project,extra={})=>spawnSync('bash',[path.join(source,'bin/phase-model.sh'),...args],{cwd,env:{...env,...extra},encoding:'utf8'});
const orderFile=path.join(state,'tool-order.json'), log=path.join(state,'phase-model.jsonl');
const order=(tools=['codex','agy','claude'],time=Date.now()/1000-1000)=>fs.writeFileSync(orderFile,JSON.stringify({version:1,orders:[{generation:1,time,tools}]}));
const table=rows=>fs.writeFileSync(path.join(project,'.ai-core/models.tsv'),rows.map(r=>r.join('\t')).join('\n')+'\n');
const records=()=>fs.readFileSync(log,'utf8').trim().split('\n').map(s=>JSON.parse(s));
let checks=0;
const check=(name,fn)=>{fn();console.log(`ok ${++checks} ${name}`);};
const select=(args,expected)=>{const r=run(args);assert.equal(r.status,0,r.stderr);assert.equal(r.stdout,expected+'\n');return r;};
const deny=(args,pattern)=>{const r=run(args);assert.equal(r.status,2,r.stdout+r.stderr);assert.equal(r.stdout,'');assert.match(r.stderr,pattern);return r;};
check('native selection without policy keeps declared rows and records no order',()=>{select(['build','high-risk'],'claude claude-sonnet-5-5 xhigh');assert.equal(records().at(-1).order,null);});
check('the keeper phase has its row on the table and phase-model accepts its word, while a misspelled word is still refused',()=>{select(['keeper','normal-hard'],'claude claude-opus-5-5 high');select(['keeper','high-risk'],'claude claude-opus-5-5 high');deny(['keepers','normal-hard'],/unknown phase: keepers/);});
const setQuota=(tool,code)=>fs.writeFileSync(path.join(quota,tool),String(code));
check('a Claude plan and re-plan route to Codex Astra and the plan check stays on Opus',()=>{
  const tuples=[[['plan','normal-hard'],'codex gpt-6-astra xhigh'],[['plan','high-risk'],'codex gpt-6-astra max'],[['re-plan','normal-hard'],'codex gpt-6-astra xhigh'],[['re-plan','high-risk'],'codex gpt-6-astra max'],[['plan-check','normal-hard','--written-by','gpt-6-astra'],'claude claude-opus-5-5 high']];
  for(const [args,expected] of tuples)select(args,expected);
  assert.equal(records().at(-1).order,null);
});
check('a Codex at its limit passes Astra and the plan and re-plan fall to Fable at the effort of the Astra row, and Astra answers again once Codex is back',()=>{
  const fable=[[['plan','normal-hard'],'claude claude-fable-5-1 xhigh'],[['plan','high-risk'],'claude claude-fable-5-1 max'],[['re-plan','normal-hard'],'claude claude-fable-5-1 xhigh'],[['re-plan','high-risk'],'claude claude-fable-5-1 max']];
  for(const code of [3,4]){
    setQuota('codex',code);
    for(const [args,expected] of fable)select(args,expected);
    const d=records().at(-1);
    assert.deepEqual(d.reasons.map(r=>[r.tool,r.exit]),[['codex',code],['claude',0]]);
    assert.match(d.reasons[0].reason,/row codex:gpt-6-astra: .*exit/);
    assert.match(d.reasons[1].reason,/row claude-fable-5-1: /);
    assert.deepEqual(d.selected,{tool:'claude',model:'claude-fable-5-1',effort:'max'});
  }
  setQuota('codex',0);
  select(['plan','normal-hard'],'codex gpt-6-astra xhigh');
  assert.equal(records().at(-1).reasons.length,1);
});
check('a writer that is the first row model selects the second row, and a Fable at its limit too leaves nothing eligible',()=>{
  select(['plan','normal-hard','--written-by','gpt-6-astra'],'claude claude-fable-5-1 xhigh');
  const d=records().at(-1);
  assert.match(d.reasons[0].reason,/row codex:gpt-6-astra: writer model gpt-6-astra is not independent/);
  assert.equal(d.reasons.length,2);
  select(['plan','normal-hard','--written-by','claude-fable-5-1'],'codex gpt-6-astra xhigh');
  setQuota('codex',3);setQuota('claude',3);
  deny(['plan','normal-hard'],/no eligible tool for plan normal-hard[\s\S]*row codex:gpt-6-astra[\s\S]*row claude-fable-5-1/);
  setQuota('codex',0);setQuota('claude',0);
});
check('work that Opus wrote is reviewed on Astra while Codex has quota and on Fable while it has none, and every other writer keeps its reviewer',()=>{
  const reviewer={mechanical:['high','xhigh','high'],'normal-hard':['xhigh','xhigh','xhigh'],'high-risk':['max','max','max']};
  for(const [cls,[opus,astra,fable]] of Object.entries(reviewer)){
    select(['review',cls,'--written-by','claude-opus-5-5'],`codex gpt-6-astra ${astra}`);
    const d=records().at(-1);
    assert.match(d.reasons[0].reason,/row claude-opus-5-5: writer model claude-opus-5-5 is not independent/);
    assert.deepEqual(d.selected,{tool:'codex',model:'gpt-6-astra',effort:astra});
    setQuota('codex',3);
    select(['review',cls,'--written-by','claude-opus-5-5'],`claude claude-fable-5-1 ${fable}`);
    assert.match(records().at(-1).reasons.map(r=>r.reason).join('\n'),/row codex:gpt-6-astra: codex quota fixture exit 3/);
    setQuota('codex',0);
    for(const writer of ['claude-sonnet-5-5','claude-fable-5-1','gpt-6-astra'])select(['review',cls,'--written-by',writer],`claude claude-opus-5-5 ${opus}`);
  }
  assert.equal(records().at(-1).order,null);
});
check('planted review table without the Astra and Fable rows refuses Opus-written work and goes red, while a Sonnet writer still selects Opus',()=>{
  const template=fs.readFileSync(path.join(source,'templates/.ai-core/models.tsv'),'utf8').split('\n').filter(l=>l&&!l.startsWith('#')).map(l=>l.split('\t'));
  const newRow=r=>r[0]==='claude'&&r[1]==='review'&&(r[3]==='claude-fable-5-1'||r[3]==='codex:gpt-6-astra');
  const withoutNew=template.filter(r=>!newRow(r));
  assert.equal(template.length-withoutNew.length,6);
  table(withoutNew);
  assert.throws(()=>select(['review','normal-hard','--written-by','claude-opus-5-5'],'codex gpt-6-astra xhigh'));
  deny(['review','normal-hard','--written-by','claude-opus-5-5'],/no eligible tool for review normal-hard[\s\S]*claude: row claude-opus-5-5: writer model claude-opus-5-5 is not independent/);
  select(['review','normal-hard','--written-by','claude-sonnet-5-5'],'claude claude-opus-5-5 xhigh');
  table(template);
  select(['review','normal-hard','--written-by','claude-opus-5-5'],'codex gpt-6-astra xhigh');
  select(['review','normal-hard','--written-by','claude-sonnet-5-5'],'claude claude-opus-5-5 xhigh');
  fs.unlinkSync(path.join(project,'.ai-core/models.tsv'));
});
check('a Claude review row that routes to Codex takes the Setup entry of codex, which replaces its table row',()=>{
  setQuota('codex',0);setQuota('claude',0);
  const setup=path.join(work,'review-setup.json');
  fs.writeFileSync(setup,JSON.stringify({review:{codex:{model:'gpt-6-astra',effort:'max',estimate_tokens:1000,budget_tokens:1500,reason:'planted'}}}));
  select(['review','normal-hard','--written-by','claude-opus-5-5','--setup-file',setup],'codex gpt-6-astra max');
  select(['review','normal-hard','--written-by','claude-opus-5-5'],'codex gpt-6-astra xhigh');
  select(['review','normal-hard','--written-by','claude-sonnet-5-5','--setup-file',setup],'claude claude-opus-5-5 xhigh');
  assert.equal(records().at(-1).order,null);
});
check('with a saved order the Astra row of the claude tool is not an execution tool, and its Fable row runs',()=>{
  order(['claude']);
  select(['plan','normal-hard'],'claude claude-fable-5-1 xhigh');
  assert.match(records().at(-1).reasons[0].reason,/row codex:gpt-6-astra routes to codex/);
  order(['codex','claude']);setQuota('codex',3);
  select(['re-plan','high-risk'],'claude claude-fable-5-1 max');
  assert.deepEqual(records().at(-1).reasons.map(r=>r.tool),['codex','claude','claude']);
  setQuota('codex',0);
  select(['re-plan','high-risk'],'codex gpt-6-astra max');
  fs.unlinkSync(orderFile);
});
check('several rows of a tool are tried in table order, the first eligible answers, and a tool with one row is unchanged',()=>{
  table([['claude','build','normal-hard','first','high'],['claude','build','normal-hard','second','low'],['claude','build','*','wild','max']]);
  select(['build','normal-hard'],'claude first high');
  assert.equal(records().at(-1).reasons.length,1);
  select(['build','normal-hard','--written-by','first'],'claude second low');
  select(['build','high-risk'],'claude wild max');
  table([['claude','build','*','wildfirst','max'],['claude','build','*','wildsecond','low']]);
  select(['build','normal-hard'],'claude wildfirst max');
  table([['claude','build','normal-hard','first','high'],['claude','build','*','wild','max']]);
  deny(['build','normal-hard','--written-by','first'],/no eligible tool for build normal-hard/);
});
check('a route goes to the row of its destination tool that names its model, with that row\'s effort, not to the first row',()=>{
  table([['claude','build','normal-hard','codex:second','high'],['codex','build','normal-hard','first','low'],['codex','build','normal-hard','second','max']]);
  select(['build','normal-hard'],'codex second max');
});
check('two rows equal in all five fields are refused as ambiguous, and rows that differ in the effort only are not',()=>{
  table([['claude','build','normal-hard','same','high'],['claude','build','normal-hard','same','high']]);
  deny(['build','normal-hard'],/ambiguous models.tsv rows/);
  table([['claude','build','*','same','high'],['claude','build','*','same','high']]);
  deny(['build','normal-hard'],/ambiguous models.tsv rows/);
  table([['claude','build','normal-hard','same','high'],['claude','build','normal-hard','same','low']]);
  select(['build','normal-hard'],'claude same high');
});
check('planted lookup that takes the last row instead of the first turns the order checks red',()=>{
  const script=path.join(source,'lib/tool-order.sh'), good=fs.readFileSync(script,'utf8');
  const planted=good.replace('for (i = 1; i <= exactCount; i++) print exact[i]','for (i = exactCount; i >= 1; i--) print exact[i]');
  assert.notEqual(planted,good);
  fs.writeFileSync(script,planted);
  fs.unlinkSync(path.join(project,'.ai-core/models.tsv'));
  assert.throws(()=>select(['plan','normal-hard'],'codex gpt-6-astra xhigh'));
  table([['claude','build','normal-hard','first','high'],['claude','build','normal-hard','second','low']]);
  assert.throws(()=>select(['build','normal-hard'],'claude first high'));
  fs.writeFileSync(script,good);
  select(['build','normal-hard'],'claude first high');
  fs.unlinkSync(path.join(project,'.ai-core/models.tsv'));
  select(['plan','normal-hard'],'codex gpt-6-astra xhigh');
});
order();
check('exact class beats wildcard; stdout is only tuple',()=>{table([['codex','build','*','wild','low'],['codex','build','normal-hard','exact','xhigh']]);select(['build','normal-hard'],'codex exact xhigh');});
check('missing row skips; agy quota receives its model',()=>{table([['agy','build','normal-hard','claude-opus-5-5-high','-']]);select(['build','normal-hard'],'agy claude-opus-5-5-high -');assert.match(fs.readFileSync(path.join(quota,'agy.args'),'utf8'),/--model claude-opus-5-5-high/);});
check('limits 3 and 4 skip; failed usage refuses without Claude fallback',()=>{table([['codex','build','*','same','high'],['claude','build','*','same','high']]);for(const code of [3,4]){fs.writeFileSync(path.join(quota,'codex'),String(code));select(['build','normal-hard'],'claude same high');assert.match(records().at(-1).reasons[0].reason,/quota fixture/);}fs.writeFileSync(path.join(quota,'codex'),'2');deny(['build','normal-hard'],/codex usage failed/);assert.equal(records().at(-1).selected,null);fs.writeFileSync(path.join(quota,'codex'),'0');});
check('all tools account for their rejection, without invented high-risk rows',()=>{table([['agy','build','normal-hard','only','-']]);deny(['build','high-risk'],/codex: no row[\s\S]*agy: no row[\s\S]*claude: no row/);});
check('writer identity ignores cross-tool prefix and changed effort',()=>{table([['codex','review','*','claude-opus-5-5','max'],['agy','review','*','claude-opus-5-5-high','-'],['claude','review','*','independent','high']]);select(['review','high-risk','--written-by','agy:claude-opus-5-5-high'],'claude independent high');order(['codex','agy']);deny(['review','high-risk','--written-by','claude:claude-opus-5-5'],/writer model/);order();deny(['plan-check','normal-hard'],/requires --written-by/);deny(['review','normal-hard'],/requires --written-by/);});
check('landed same-model plan-check rows are skipped without rewriting table',()=>{fs.unlinkSync(path.join(project,'.ai-core/models.tsv'));select(['plan-check','high-risk','--written-by','gpt-6-astra'],'claude claude-opus-5-5 high');order(['agy','claude']);deny(['plan-check','normal-hard','--written-by','claude-opus-5-5'],/not independent/);order();});
check('explicit order cannot disguise a route as its earlier source',()=>{table([['codex','build','*','claude:routed','low'],['claude','build','*','routed','high']]);select(['build','normal-hard'],'claude routed high');assert.match(records().at(-1).reasons[0].reason,/routes to claude/);fs.unlinkSync(orderFile);select(['build','normal-hard'],'claude routed high');select(['build','normal-hard'],'claude routed high');const r=run(['build','normal-hard'],project,{CODEX_THREAD_ID:'fixture'});assert.equal(r.stdout,'claude routed high\n');order();});
check('decision records include time project class writer quota and snapshot',()=>{const d=records().at(-1);assert.equal(d.version,1);assert.ok(d.time>=d.began);assert.equal(d.project,project);assert.equal(d.phase,'build');assert.equal(d.class,'normal-hard');assert.equal(d.writer,'');assert.ok(Array.isArray(d.reasons));});
check('required decision write failure suppresses successful tuple',()=>{const saved=fs.readFileSync(log);fs.unlinkSync(log);fs.mkdirSync(log);deny(['build','normal-hard'],/cannot read/);fs.rmdirSync(log);fs.writeFileSync(log,saved);});
check('malformed decision history cannot be silently appended',()=>{const saved=fs.readFileSync(log);fs.appendFileSync(log,'{\n');deny(['build','normal-hard'],/cannot read/);fs.writeFileSync(log,saved);});
const asyncRun=(args,cwd=project)=>new Promise(resolve=>{const p=spawn('bash',[path.join(source,'bin/phase-model.sh'),...args],{cwd,env});let stdout='',stderr='';p.stdout.on('data',b=>stdout+=b);p.stderr.on('data',b=>stderr+=b);p.on('close',status=>resolve({stdout,stderr,status}));});
const pause=ms=>new Promise(r=>setTimeout(r,ms));
table([['codex','build','normal-hard','same','high'],['codex','build','high-risk','same','high']]);
check('concurrency setup uses project-specific rows',()=>{fs.writeFileSync(path.join(other,'.ai-core/models.tsv'),'codex\tbuild\t*\tother\tmax\n');});
let concurrent=await Promise.all([asyncRun(['build','normal-hard']),asyncRun(['build','high-risk'],other)]);
check('concurrent projects have complete records without cross-project attribution',()=>{assert.deepEqual(concurrent.map(r=>r.status),[0,0],JSON.stringify(concurrent));assert.deepEqual(new Set(concurrent.map(r=>r.stdout)),new Set(['codex same high\n','codex other max\n']));assert.deepEqual(new Set(records().slice(-2).map(d=>d.project)),new Set([project,other]));});
concurrent=await Promise.all([asyncRun(['build','normal-hard']),asyncRun(['build','high-risk'])]);
check('competing same tuple selections retain both classes and snapshots',()=>{assert.deepEqual(concurrent.map(r=>r.status),[0,0],JSON.stringify(concurrent));assert.deepEqual(new Set(records().slice(-2).map(d=>d.class)),new Set(['normal-hard','high-risk']));assert.ok(records().slice(-2).every(d=>d.order.generation===1));});
fs.writeFileSync(path.join(quota,'hold'),'');const running=asyncRun(['build','normal-hard']);
for(let n=0;!fs.existsSync(path.join(quota,'ready'));n++){assert.ok(n<200,'quota reader did not reach barrier');await pause(25);}
const replacement=spawn('bash',['-c','. "$1/lib/tool-order.sh"; tool_order_paths; tool_order_save claude','fixture',source],{env,stdio:['ignore','pipe','pipe']});
const replaced=new Promise(resolve=>replacement.on('close',resolve));assert.equal(await replaced,0);
fs.unlinkSync(path.join(quota,'hold'));const raced=await running;
check('quota reads hold no global lock and an order race records refusal with its snapshot',()=>{assert.equal(raced.status,2,raced.stderr);assert.equal(raced.stdout,'');assert.match(raced.stderr,/order changed/);assert.equal(records().at(-1).order.generation,1);assert.equal(records().at(-1).selected,null);assert.equal(JSON.parse(fs.readFileSync(orderFile)).orders.at(-1).generation,2);});

const sessions=path.join(state,'sessions'), bin=path.join(work,'bin'), agents=path.join(work,'agents.json');
fs.mkdirSync(bin);fs.writeFileSync(path.join(bin,'claude'),'#!/usr/bin/env bash\ncat "$NATIVE_AGENTS"\n');fs.chmodSync(path.join(bin,'claude'),0o755);
const auditEnv={...env,PATH:bin+path.delimiter+process.env.PATH,NATIVE_AGENTS:agents};
const audit=()=>spawnSync('bash',['-c','. "$1/lib/tool-order.sh"; tool_order_audit','audit',source],{env:auditEnv,cwd:other,encoding:'utf8'});
const time=Date.now()/1000-500;
const name='build10001-same-high-250k-abcde';
const decision=(overrides={})=>({version:1,began:time+9,time:time+10,project,phase:'build',class:'normal-hard',writer:'',order:{generation:1,time,tools:['codex','agy','claude']},selected:{tool:'codex',model:'same',effort:'high'},refusal:'',reasons:[{tool:'codex',exit:0,reason:'quota left at decision'}],...overrides});
let current;
function fixture({tool='claude',model='same',effort='high',n=name,projectFolder=project}={}) {
  fs.rmSync(sessions,{recursive:true,force:true});fs.mkdirSync(sessions);order(['codex','agy','claude'],time);
  fs.writeFileSync(log,JSON.stringify(decision({project:projectFolder}))+'\n');
  fs.writeFileSync(agents,'[]');for(const t of ['codex','agy'])fs.writeFileSync(path.join(state,`${t==='codex'?'codex-sessions':'agy-conversations'}.tsv`),'');
  const num=Number(/^[a-z-]+(\d+)/.exec(n)[1]), block=Math.floor(num/10000)*10000;
  fs.writeFileSync(path.join(sessions,`l${block}.block`),`${projectFolder}\tagy\n`);
  const id=`${tool}-identity`, observation={version:1,kind:'attempt',operation:'start',tool,model,effort,invoked:time+20,observed:time+21,phase:'build'};
  fs.writeFileSync(path.join(sessions,`${n}.start.jsonl`),JSON.stringify(observation)+'\n'+JSON.stringify({...observation,kind:'native',nativeIdentity:id})+'\n');
  if(tool==='claude')fs.writeFileSync(agents,JSON.stringify([{name:n,sessionId:id,id:'short-id',cwd:projectFolder,model,effort}]));
  else {
    fs.writeFileSync(path.join(state,`${tool==='codex'?'codex-sessions':'agy-conversations'}.tsv`),`${n}\t${id}\n`);
    fs.writeFileSync(path.join(sessions,`${n}.out`),JSON.stringify(tool==='codex'?{type:'thread.started',thread_id:id}:{conversation_id:id})+'\n');
  }
  current={n,id,tool,observation,file:path.join(sessions,`${n}.start.jsonl`)};return current;
}
const unknown=(pattern)=>{const r=audit();assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/UNKNOWN/);assert.match(r.stdout,pattern);assert.doesNotMatch(r.stdout,/^OK |^RED /m);return r.stdout;};
check('planted Claude start after a Codex choice is RED on the shared tuple',()=>{fixture();const r=audit();assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/^RED .*actual claude same high; selected codex same high/m,JSON.stringify(r));assert.match(r.stdout,/claude 1; matched 1\/1/);assert.match(r.stdout,/quota left at decision/);});
check('agy effort suffix and Claude effective effort bind across tools',()=>{fixture({model:'claude-opus-5-5'});fs.writeFileSync(log,JSON.stringify(decision({selected:{tool:'agy',model:'claude-opus-5-5-high',effort:'-'}}))+'\n');assert.match(audit().stdout,/^RED /m);});
check('innocent Claude-only order is green',()=>{fixture();order(['claude'],time);fs.writeFileSync(log,JSON.stringify(decision({order:{generation:1,time,tools:['claude']},selected:{tool:'claude',model:'same',effort:'high'}}))+'\n');assert.match(audit().stdout,/^OK /m);assert.doesNotMatch(audit().stdout,/^RED /m);});
check('legitimate fallback uses historical exhausted Codex reason',()=>{fixture();fs.writeFileSync(log,JSON.stringify(decision({selected:{tool:'claude',model:'same',effort:'high'},reasons:[{tool:'codex',exit:3,reason:'limit at selection'},{tool:'claude',exit:0,reason:'left'}]}))+'\n');assert.match(audit().stdout,/^OK .*codex exit 3: limit at selection/m);});
for(const [label,change,reason] of [
  ['different model',()=>fixture({model:'different'}),/missing matching decision/],
  ['different effort',()=>fixture({effort:'max'}),/missing matching decision/],
  ['newer unrelated project',()=>{fixture();fs.appendFileSync(log,JSON.stringify(decision({project:other,time:time+19}))+'\n');},/^RED /m],
  ['missing block',()=>{fixture();fs.unlinkSync(path.join(sessions,'l10000.block'));},/missing block claim/],
  ['conflicting native project',()=>{fixture();fs.writeFileSync(agents,JSON.stringify([{name,sessionId:current.id,cwd:other}]));},/cwd conflicts/],
  ['missing Claude cwd',()=>{fixture();fs.writeFileSync(agents,JSON.stringify([{name,sessionId:current.id}]));},/cwd missing|missing.*native/],
  ['no longer native Claude',()=>{fixture();fs.writeFileSync(agents,'[]');},/missing.*native evidence/],
  ['nonunique block',()=>{fixture();fs.copyFileSync(path.join(sessions,'l10000.block'),path.join(sessions,'l010000.block'));},/non-unique block/],
  ['malformed block',()=>{fixture();fs.writeFileSync(path.join(sessions,'l10000.block'),'not a claim\n');},/malformed block/],
  ['bad phase number',()=>fixture({n:'build10000-same-high-250k-abcde'}),/invalid phase number/],
  ['malformed observation',()=>{fixture();fs.appendFileSync(current.file,'garbage\n');},/malformed JSON/],
  ['missing historical timing',()=>{fixture();fs.unlinkSync(current.file);},/missing launch timing/],
  ['tied latest time',()=>{fixture();fs.appendFileSync(log,JSON.stringify(decision())+'\n');},/tied latest/],
  ['decision in native interval',()=>{fixture();fs.appendFileSync(log,JSON.stringify(decision({time:time+20.5}))+'\n');},/boundary inside/],
  ['class conflict',()=>{fixture();fs.appendFileSync(log,JSON.stringify(decision({time:time+11,class:'high-risk'}))+'\n');},/class or writer/],
  ['writer conflict',()=>{fixture();fs.appendFileSync(log,JSON.stringify(decision({time:time+11,writer:'someone'}))+'\n');},/class or writer/],
  ['overlapping selections',()=>{fixture();fs.appendFileSync(log,JSON.stringify(decision({began:time+9.5,time:time+11}))+'\n');},/overlapping selections/],
  ['order changed',()=>{fixture();const s=JSON.parse(fs.readFileSync(orderFile));s.orders.push({generation:2,time:time+19,tools:['claude']});fs.writeFileSync(orderFile,JSON.stringify(s));},/order changed/],
  ['order interval boundary',()=>{fixture();const s=JSON.parse(fs.readFileSync(orderFile));s.orders.push({generation:2,time:time+20.5,tools:['claude']});fs.writeFileSync(orderFile,JSON.stringify(s));},/order changed/],
  ['old ambiguous phase letter',()=>fixture({n:'p10001-same-high-250k-abcde'}),/old phase letter/]
])check(label,()=>{change();if(label==='newer unrelated project')assert.match(audit().stdout,reason);else unknown(reason);});
check('a keeper session is audited by its phase word, like every numbered phase',()=>{fixture({n:'keeper10001-same-high-150k-abcde'});for(const f of [current.file,log])fs.writeFileSync(f,fs.readFileSync(f,'utf8').replaceAll('"phase":"build"','"phase":"keeper"'));assert.match(audit().stdout,/^RED keeper10001-same-high-150k-abcde start/m);});
check('an old letter with independent phase evidence can correlate',()=>{fixture({n:'i10001-same-high-250k-abcde'});assert.match(audit().stdout,/^RED /m);});
check('prepared artifacts and attempts are no start, never compliance',()=>{fixture();fs.writeFileSync(agents,'[]');fs.writeFileSync(current.file,JSON.stringify(current.observation)+'\n');for(const suffix of ['brief.md','report.md','out'])fs.writeFileSync(path.join(sessions,`${name}.${suffix}`),'');assert.match(audit().stdout,/NO START .*launch attempt only/);assert.match(audit().stdout,/claude 0/);});
check('Codex and agy in both projects bind registry output and block claim',()=>{for(const p of [project,other])for(const t of ['codex','agy']){fixture({tool:t,projectFolder:p});const r=audit();assert.equal(r.status,0,r.stderr);assert.match(r.stdout,t==='codex'?/^OK /m:/^RED /m);assert.match(r.stdout,new RegExp(`${t} 1`));}});
check('registry/output mismatch and duplicate native identities are unknown',()=>{for(const t of ['codex','agy']){fixture({tool:t});const registry=path.join(state,`${t==='codex'?'codex-sessions':'agy-conversations'}.tsv`);fs.appendFileSync(registry,`${name}\tforeign-id\n`);unknown(/identity conflict|several/);}});
check('same name under agy and Claude does not disguise execution tool',()=>{fixture({tool:'agy'});fs.writeFileSync(agents,JSON.stringify([{name,sessionId:'claude-id',cwd:project}]));fs.appendFileSync(current.file,JSON.stringify({...current.observation,tool:'claude',kind:'attempt'})+'\n'+JSON.stringify({...current.observation,tool:'claude',kind:'native',nativeIdentity:'claude-id'})+'\n');unknown(/indistinguishable|overlapping/);});
check('helper registry lines are excluded',()=>{fixture({tool:'agy'});fs.appendFileSync(path.join(state,'agy-conversations.tsv'),`agy-${name}\thelper\nagy-${name}-task\thelper-task\n`);const r=audit();assert.match(r.stdout,/agy 1/);assert.doesNotMatch(r.stdout,/helper/);});
check('one decision with two indistinguishable starts and reversed launches is unknown',()=>{fixture();const n='build10002-same-high-250k-bcdef';const obs=current.observation;fs.writeFileSync(path.join(sessions,`${n}.start.jsonl`),JSON.stringify({...obs,invoked:time+19,observed:time+22})+'\n'+JSON.stringify({...obs,kind:'native',invoked:time+19,observed:time+22,nativeIdentity:'second'})+'\n');fs.writeFileSync(agents,JSON.stringify([{name,sessionId:current.id,cwd:project},{name:n,sessionId:'second',cwd:project}]));unknown(/one decision has indistinguishable|overlapping native/);});
check('resume keeps original count and checks new actual model against a fresh decision',()=>{fixture();const d=decision({began:time+30,time:time+31,selected:{tool:'claude',model:'new-model',effort:'max'}});fs.appendFileSync(log,JSON.stringify(d)+'\n');const o={...current.observation,operation:'resume',model:'new-model',effort:'max',invoked:time+40,observed:time+41};fs.appendFileSync(current.file,JSON.stringify(o)+'\n'+JSON.stringify({...o,kind:'native',nativeIdentity:current.id})+'\n');fs.writeFileSync(agents,JSON.stringify([{name,sessionId:current.id,cwd:project}]));const r=audit();assert.match(r.stdout,/^OK .*resume: actual claude new-model max/m);assert.match(r.stdout,/claude 1; matched 2\/2/);});
check('worktree native cwd resolves to project; UI-test throwaway uses its block',()=>{const repo=path.join(project,'repo'), wt=path.join(work,'linked-tree');fs.mkdirSync(repo);let r=spawnSync('git',['init','-q',repo]);assert.equal(r.status,0);r=spawnSync('git',['-C',repo,'-c','user.name=check','-c','user.email=check@localhost','commit','--allow-empty','-qm','fixture']);assert.equal(r.status,0);r=spawnSync('git',['-C',repo,'worktree','add','-qb','fixture',wt]);assert.equal(r.status,0);fixture();fs.writeFileSync(agents,JSON.stringify([{name,sessionId:current.id,cwd:wt}]));assert.match(audit().stdout,/^RED /m);fixture({n:'ui-test10001-same-high-100k-abcde'});fs.writeFileSync(log,JSON.stringify(decision({phase:'ui-test'}))+'\n');const obs={...current.observation,phase:'ui-test'};fs.writeFileSync(current.file,JSON.stringify(obs)+'\n'+JSON.stringify({...obs,kind:'native',nativeIdentity:current.id})+'\n');fs.writeFileSync(agents,JSON.stringify([{name:current.n,sessionId:current.id,cwd:other}]));assert.match(audit().stdout,/^RED /m);});
check('audit failure names malformed global history',()=>{fixture();fs.appendFileSync(log,'{\n');const r=audit();assert.equal(r.status,2);assert.match(r.stderr,/audit read failure.*malformed/);});
check('a selection whose project folder is gone matches nothing and leaves the audit readable',()=>{fixture();const gone=path.join(work,'removed project');fs.mkdirSync(gone);const folder=fs.realpathSync(gone);fs.rmdirSync(gone);fs.appendFileSync(log,JSON.stringify(decision({project:folder,began:time+12,time:time+13,selected:{tool:'claude',model:'same',effort:'high'}}))+'\n');const r=audit();assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/^RED /m);fs.appendFileSync(log,JSON.stringify(decision({project:'relative/project'}))+'\n');assert.match(audit().stderr,/audit read failure.*malformed selection/);});
check('old single-letter names with artifacts only are counted in one line; a phase-word name stays listed',()=>{fixture();for(const n of ['i10007-same-high-250k-aaaaa','p10008-same-high-150k-bbbbb'])fs.writeFileSync(path.join(sessions,`${n}.brief.md`),'');fs.writeFileSync(path.join(sessions,'review10009-same-high-100k-ccccc.brief.md'),'');const r=audit();assert.equal(r.status,0,r.stderr);assert.doesNotMatch(r.stdout,/i10007|p10008/);assert.match(r.stdout,/^NO START 2 old single-letter names with artifacts only/m);assert.match(r.stdout,/^NO START review10009-same-high-100k-ccccc: artifacts only/m);assert.match(r.stdout,/; no start 3;/);assert.match(r.stdout,/^RED /m);});
check('planted latest-global matching defect is caught while innocent project stays green',()=>{fixture();const file=path.join(source,'lib/tool-order.sh'), good=fs.readFileSync(file,'utf8');fs.appendFileSync(log,JSON.stringify(decision({project:other,began:time+18,time:time+19,selected:{tool:'claude',model:'same',effort:'high'}}))+'\n');assert.match(audit().stdout,/^RED /m);fs.writeFileSync(file,good.replace('d.project === s.project && d.phase === s.phase','d.phase === s.phase'));assert.match(audit().stdout,/^OK /m);fs.writeFileSync(file,good);assert.match(audit().stdout,/^RED /m);});
check('refusal after a previous success cannot make a later start compliant',()=>{fixture();fs.appendFileSync(log,JSON.stringify(decision({began:time+17,time:time+18,selected:null,refusal:'quota failed'}))+'\n');unknown(/later selection refused/);});
check('a nonpersistent UI-test without native identity is unknown',()=>{fixture({n:'ui-test10001-same-high-100k-abcde'});fs.writeFileSync(agents,'[]');fs.writeFileSync(current.file,JSON.stringify({...current.observation,phase:'ui-test'})+'\n');unknown(/no usable native identity/);});
check('a null observation is unknown rather than a parser crash',()=>{fixture();fs.appendFileSync(current.file,'null\n');unknown(/malformed launch observation/);});
check('Claude in both projects uses each canonical claim',()=>{for(const p of [project,other]){fixture({projectFolder:p});assert.match(audit().stdout,/^RED /m);}});
check('several Claude native identities under one name are unknown',()=>{fixture();const a=JSON.parse(fs.readFileSync(agents));a.push({...a[0],sessionId:'another'});fs.writeFileSync(agents,JSON.stringify(a));unknown(/several claude native identities|non-unique/);});
check('planted failed-quota fallback is red before restoring the fail-closed selector',()=>{order();table([['codex','build','*','same','high'],['claude','build','*','same','high']]);fs.writeFileSync(path.join(quota,'codex'),'2');const file=path.join(source,'bin/phase-model.sh'),good=fs.readFileSync(file,'utf8');fs.writeFileSync(file,good.replace('3|4) ;;','2|3|4) ;;'));assert.throws(()=>deny(['build','normal-hard'],/usage failed/));fs.writeFileSync(file,good);deny(['build','normal-hard'],/usage failed/);fs.writeFileSync(path.join(quota,'codex'),'0');});
check('planted same-writer selection is red before restoring normalized independence',()=>{table([['codex','review','*','claude-opus-5-5','max'],['claude','review','*','independent','high']]);const file=path.join(source,'bin/phase-model.sh'),good=fs.readFileSync(file,'utf8');fs.writeFileSync(file,good.replace('[ "$(phase_model_base "$model")" = "$(phase_model_base "$writer")" ]','[ writer = other ]'));assert.throws(()=>select(['review','high-risk','--written-by','agy:claude-opus-5-5-high'],'claude independent high'));fs.writeFileSync(file,good);select(['review','high-risk','--written-by','agy:claude-opus-5-5-high'],'claude independent high');});
check('malformed model tokens cannot contaminate the stdout tuple',()=>{table([['codex','build','*','two words','high']]);deny(['build','normal-hard'],/cannot read/);});
check('a native-source read failure is named and fails the audit',()=>{fixture();const file=path.join(bin,'claude'),good=fs.readFileSync(file);fs.writeFileSync(file,'#!/usr/bin/env bash\nexit 2\n');const r=audit();assert.equal(r.status,2);assert.match(r.stderr,/audit read failure.*claude agents/);fs.writeFileSync(file,good);});
const without=path.join(work,'without-claude'), which=n=>spawnSync('bash',['-c',`command -v ${n}`],{encoding:'utf8'}).stdout.trim();
fs.mkdirSync(without);for(const n of ['bash','node','git','jq'])fs.symlinkSync(which(n),path.join(without,n));
const auditWithoutClaude=()=>spawnSync(which('bash'),['-c','. "$1/lib/tool-order.sh"; tool_order_audit','audit',source],{env:{...auditEnv,PATH:without},cwd:other,encoding:'utf8'});
check('a machine without the claude command and with no Claude start is no audit failure',()=>{fixture({tool:'codex'});const r=auditWithoutClaude();assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/^OK .*actual codex same high/m);assert.match(r.stdout,/codex 1/);});
check('a Claude start on a machine without the claude command is named and fails the audit',()=>{fixture();const r=auditWithoutClaude();assert.equal(r.status,2);assert.match(r.stderr,/audit read failure.*claude agents/);assert.match(r.stdout,/^UNKNOWN .*claude agents --json failed/m);assert.doesNotMatch(r.stdout,/^OK |^RED /m);});
check('a machine without node names the audit it cannot run',()=>{fixture({tool:'codex'});const bare=path.join(work,'without-node');fs.mkdirSync(bare);for(const n of ['bash','git','jq'])fs.symlinkSync(which(n),path.join(bare,n));const r=spawnSync(which('bash'),['-c','. "$1/lib/tool-order.sh"; tool_order_audit','audit',source],{env:{...auditEnv,PATH:bare},cwd:other,encoding:'utf8'});assert.equal(r.status,2);assert.match(r.stderr,/audit read failure.*node/);});
check('a mkdir that cannot tell a held lock does not decide the order lock, and a lock taken with mkdir is caught',()=>{
  const plant=path.join(work,'plant-mkdir');fs.mkdirSync(plant);
  fs.writeFileSync(path.join(plant,'mkdir'),'#!/usr/bin/env bash\nfor last; do :; done\ncase "$last" in *.lock) exit 0 ;; esac\nexec "$REAL_MKDIR" "$@"\n');fs.chmodSync(path.join(plant,'mkdir'),0o755);
  const held={PATH:plant+path.delimiter+process.env.PATH,REAL_MKDIR:which('mkdir')}, lock=path.join(state,'tool-order.lock'), file=path.join(source,'lib/tool-order.sh'), good=fs.readFileSync(file,'utf8');
  order(['claude']);table([['claude','build','*','same','high']]);fs.writeFileSync(lock,'');
  const refused=run(['build','normal-hard'],project,held);assert.equal(refused.status,2);assert.match(refused.stderr,/cannot lock/);assert.ok(fs.existsSync(lock));
  fs.writeFileSync(file,good.replace('( set -C; : > "$TOOL_ORDER_LOCK" )','mkdir "$TOOL_ORDER_LOCK"').replace('rm "$TOOL_ORDER_LOCK"','rmdir "$TOOL_ORDER_LOCK"'));assert.notEqual(fs.readFileSync(file,'utf8'),good);
  const taken=run(['build','normal-hard'],project,held);assert.doesNotMatch(taken.stderr,/cannot lock/);
  fs.writeFileSync(file,good);fs.unlinkSync(lock);select(['build','normal-hard'],'claude same high');
});
check('unreadable order refuses and records the failed selection',()=>{fs.writeFileSync(orderFile,'bad');const before=records().length;deny(['build','normal-hard'],/cannot read/);assert.equal(records().length,before+1);assert.equal(records().at(-1).selected,null);order();});
console.log(`phase-model: ${checks} checks passed`);
JS
