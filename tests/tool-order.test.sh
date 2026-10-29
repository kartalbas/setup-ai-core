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
import {spawnSync} from 'node:child_process';
const [root, work] = process.argv.slice(2), copy=path.join(work,'source');
for (const dir of ['bin','lib','templates/.ai-core']) fs.mkdirSync(path.join(copy,dir),{recursive:true});
for (const file of ['bin/tool-order.sh','bin/phase-model.sh','lib/common.sh','lib/tool-order.sh','templates/.ai-core/models.tsv']) fs.copyFileSync(path.join(root,file),path.join(copy,file));
const quota=path.join(copy,'bin/usage.sh');
fs.writeFileSync(quota,`#!/usr/bin/env bash
tool="$2"
printf '%s\\n' "usage $tool $*"
exit "$(cat "$QUOTA/$tool")"
`);
const q=path.join(work,'quota'); fs.mkdirSync(q); for(const t of ['codex','agy','claude'])fs.writeFileSync(path.join(q,t),'0');
const a=path.join(work,'project one'), b=path.join(work,'project two');
for(const p of [a,b])fs.mkdirSync(path.join(p,'.ai-core'),{recursive:true});
let count=0;
const run=(args=[],cwd=a)=>spawnSync('bash',[path.join(copy,'bin/tool-order.sh'),...args],{cwd,env:{...process.env,QUOTA:q},encoding:'utf8'});
const check=(name,fn)=>{fn();console.log(`ok ${++count} ${name}`);};
const file=path.join(process.env.AI_CORE_HOME,'.ai-core/tool-order.json');
const refusal=(input,pattern)=>{const before=fs.readFileSync(file,'utf8'), r=run(input);assert.equal(r.status,2,r.stderr);assert.match(r.stderr,pattern);assert.equal(fs.readFileSync(file,'utf8'),before);};
check('unset has no invented order or time',()=>{const r=run();assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/not set/);assert.doesNotMatch(r.stdout,/set at:/);assert.equal(fs.existsSync(file),false);});
check('clear is advertised and can be repeated before any order is saved',()=>{
  const help=run(['--help']);assert.equal(help.status,0);assert.match(help.stdout,/\[TOOL\[,TOOL\.\.\.\] \| --clear\]/);assert.match(help.stdout,/native tool and the routing rows/);
  for(let generation=1;generation<=2;generation++){
    const r=run(['--clear']);assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/^tool order: not set; native-tool selection\ncleared at: /);
    const entry=JSON.parse(fs.readFileSync(file)).orders.at(-1);assert.equal(entry.generation,generation);assert.deepEqual(entry.tools,[]);
  }
  fs.unlinkSync(file);
});
check('machine-wide order and actual set time survive a fresh shell and project',()=>{const before=Date.now()/1000, r=run(['codex,agy,claude']);assert.equal(r.status,0,r.stderr);const state=JSON.parse(fs.readFileSync(file));assert.deepEqual(state.orders[0].tools,['codex','agy','claude']);assert.ok(state.orders[0].time>=before && state.orders[0].time<=Date.now()/1000);assert.equal(run([],a).stdout,run([],b).stdout);});
for(const input of ['',',codex','codex,','codex,,agy','codex,codex','unknown','codex,unknown','codex, agy'])check(`planted invalid order ${JSON.stringify(input)} preserves preference`,()=>refusal([input],/empty|duplicate|unknown/));
check('missing project rows refuse whole replacement',()=>{fs.writeFileSync(path.join(a,'.ai-core/models.tsv'),'claude\tbuild\t*\tdeclared\thigh\n');refusal(['codex,claude'],/no model rows/);fs.unlinkSync(path.join(a,'.ai-core/models.tsv'));});
check('failed usage support refuses; quota exhaustion still saves preference',()=>{fs.writeFileSync(path.join(q,'agy'),'2');refusal(['claude,agy'],/agy usage failed/);for(const code of [3]){fs.writeFileSync(path.join(q,'agy'),String(code));assert.equal(run(['agy,claude']).status,0);}fs.writeFileSync(path.join(q,'agy'),'0');});
check('explicit Claude-only order is innocent',()=>{const r=run(['claude']);assert.equal(r.status,0,r.stderr);assert.deepEqual(JSON.parse(fs.readFileSync(file)).orders.at(-1).tools,['claude']);});
check('clear removes the saved order, keeps its history, and a new order follows it',()=>{
  const before=JSON.parse(fs.readFileSync(file)).orders;
  for(const args of [['--clear','codex'],['codex','--clear'],['--clear,codex'],['codex,--clear']])refusal(args,/takes no order|takes one|unknown tool/);
  for(const t of ['codex','agy','claude'])fs.writeFileSync(path.join(q,t),'2');
  const r=run(['--clear']);assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/^tool order: not set; native-tool selection\ncleared at: /);
  const s=JSON.parse(fs.readFileSync(file));assert.deepEqual(s.orders.slice(0,-1),before);assert.equal(s.orders.length,before.length+1);assert.deepEqual(s.orders.at(-1).tools,[]);assert.equal(s.orders.at(-1).generation,before.length+1);assert.match(run().stdout,/cleared at:/);
  for(const t of ['codex','agy','claude'])fs.writeFileSync(path.join(q,t),'0');
  const n=run(['codex,claude']);assert.equal(n.status,0,n.stderr);const t=JSON.parse(fs.readFileSync(file)).orders.at(-1);assert.deepEqual(t.tools,['codex','claude']);assert.equal(t.generation,before.length+2);assert.match(run().stdout,/^tool order: codex,claude\nset at: /);
});
check('malformed state is never replaced or invented',()=>{const good=fs.readFileSync(file);for(const bad of ['{','null','{"version":1,"orders":[]}']){fs.writeFileSync(file,bad);assert.equal(run().status,2);assert.equal(run(['codex']).status,2);assert.equal(fs.readFileSync(file,'utf8'),bad);}fs.writeFileSync(file,good);});
check('unreadable and unwritable state failures are named',()=>{const good=fs.readFileSync(file);fs.chmodSync(file,0);assert.equal(run().status,2);fs.chmodSync(file,0o600);assert.deepEqual(fs.readFileSync(file),good);const dir=path.dirname(file);fs.chmodSync(dir,0o500);const r=run(['codex']);assert.equal(r.status,2);assert.match(r.stderr,/cannot/);fs.chmodSync(dir,0o700);assert.deepEqual(fs.readFileSync(file),good);});
check('planted non-atomic invalid replacement turns the preservation check red',()=>{const script=path.join(copy,'bin/tool-order.sh'), source=fs.readFileSync(script,'utf8');fs.writeFileSync(script,source.replace('order="$1"','order="$1"\nprintf bad > "$TOOL_ORDER_FILE"'));const r=run(['unknown']);assert.equal(r.status,2);assert.equal(fs.readFileSync(file,'utf8'),'bad');fs.writeFileSync(script,source);fs.unlinkSync(file);assert.equal(run(['claude']).status,0);});
console.log(`tool-order: ${count} checks passed`);
JS
