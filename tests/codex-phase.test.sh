#!/usr/bin/env bash
# Execute the saved Codex launch with a stand-in and refute stale routing instructions.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export HOME="$WORK/home" AI_CORE_HOME="$WORK/core"
mkdir -p "$HOME/.ai-core/sessions" "$WORK/bin" "$WORK/project folder"
export CAPTURE="$WORK/argv"
cat > "$WORK/bin/codex" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE"
[ -z "$(cat)" ] || exit 9
printf '%s\n' '{"type":"thread.started","thread_id":"fixture-thread"}' '{"type":"item.completed","item":{"type":"agent_message","text":"fixture final report"}}' '{"type":"turn.completed","usage":{"input_tokens":2321047,"cached_input_tokens":2174976,"cache_write_input_tokens":0,"output_tokens":21658,"reasoning_output_tokens":11479}}'
TOOL
chmod +x "$WORK/bin/codex"
printf 'fixture brief\n' > "$WORK/brief"
export PATH="$WORK/bin:$PATH"
# The checker reads a source tree, so each single-sentence regression can be planted in a copy.
cat > "$WORK/check.mjs" <<'JS'
import fs from 'node:fs';
const root=process.argv[2], read=p=>fs.readFileSync(root+'/'+p,'utf8').replace(/^# ?/gm,'').replace(/\s+/g,' ');
const contains=(p,s)=>{if(!read(p).includes(s))throw Error(p+': missing '+s)};
const base='skills/person-in-charge/';
contains(base+'references/codex.md','including Claude Code');
contains(base+'references/claude.md','reads `references/codex.md`');
contains(base+'SKILL.md',"until the owner withdraws it or the coordinator restarts");
contains(base+'SKILL.md',"after a restart, your own table rows apply again");
contains(base+'SKILL.md',"destination tool's row of the same phase and class");
contains(base+'SKILL.md',"selected tool's phase budget");
contains(base+'references/codex.md','ai-core usage --tool codex');
contains(base+'references/codex.md','Exit 2');
contains(base+'references/codex.md','/dev/null');
contains(base+'references/codex.md','codex-sessions.tsv');
contains(base+'references/codex.md','last `agent_message`');
contains(base+'references/codex.md','--file ~/.ai-core/sessions/<session name>.out');
contains(base+'references/codex.md','sandbox_workspace_write.writable_roots=');
if(read(base+'references/codex.md').includes('keeps the folders of its start'))throw Error('false resume folder claim');
const reference=fs.readFileSync(root+'/'+base+'references/codex.md','utf8');
const start=reference.split('## Start a phase session')[1].split('## Ask the owner')[0];
if(start.indexOf(': > ~/.ai-core/sessions/<session name>.out')<0 || start.indexOf(': > ~/.ai-core/sessions/<session name>.out')>start.indexOf('    codex exec'))throw Error('output must exist before watching');

contains('rules/80-working-style-for-agents.md','on its own because a quota ran out');
contains('rules/80-working-style-for-agents.md','every session using that limited account or model');
contains('README.md',"expires on withdrawal or coordinator restart");
contains('templates/.ai-core/models.tsv',"A temporary owner instruction leaves these rows unchanged");
contains(base+'briefs/build.md',"You build it yourself, in your own tool");
JS
node "$WORK/check.mjs" "$ROOT" || fail 'phase routing contract'
cp -R "$ROOT/skills" "$WORK/skills"
mkdir -p "$WORK/rules" "$WORK/templates/.ai-core"
cp "$ROOT/rules/80-working-style-for-agents.md" "$WORK/rules/"
cp "$ROOT/templates/.ai-core/models.tsv" "$WORK/templates/.ai-core/"
cp "$ROOT/README.md" "$WORK/"
for pair in 'references/codex.md|including Claude Code' 'SKILL.md|until the owner withdraws it or the coordinator restarts' 'SKILL.md|after a restart, your own table rows apply again' 'references/codex.md|last `agent_message`' 'references/codex.md|--file ~/.ai-core/sessions/<session name>.out' 'references/codex.md|sandbox_workspace_write.writable_roots='; do
  file="${pair%%|*}"; phrase="${pair#*|}"
  FILE="$WORK/skills/person-in-charge/$file" PHRASE="$phrase" node -e 'const fs=require("fs"),p=process.env.FILE,s=fs.readFileSync(p,"utf8");fs.writeFileSync(p,s.replace(new RegExp(process.env.PHRASE.split(/\s+/).map(x=>x.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")).join("\\s+")),"stale instruction"))'
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "stale instruction escaped: $phrase"; fi
  cp "$ROOT/skills/person-in-charge/$file" "$WORK/skills/person-in-charge/$file"
done
# Run the command from the reference rather than a separately maintained launcher.
REF="$ROOT/skills/person-in-charge/references/codex.md" WORK="$WORK" node <<'JS'
const fs=require('fs'),s=fs.readFileSync(process.env.REF,'utf8').split('## Start a phase session')[1];
const command=s.match(/^    codex exec[\s\S]*?(?=\n\n)/m)[0].replace(/^    /gm,'').replaceAll('<model>','gpt-6-astra').replaceAll('<effort>','max').replaceAll('<project folder>','"'+process.env.WORK+'/project folder"').replaceAll('<brief file>','"'+process.env.WORK+'/brief"').replaceAll('<session name>','fixture');
fs.writeFileSync(process.env.WORK+'/launch',command+'\n');
JS
bash "$WORK/launch"
node - "$CAPTURE" "$WORK" <<'JS'
const fs=require('fs'),args=fs.readFileSync(process.argv[2],'utf8').trimEnd().split('\n'),work=process.argv[3];
for(const [flag,value] of [['-p','ai-core'],['-m','gpt-6-astra'],['-c','model_reasoning_effort=max'],['-C',work+'/project folder'],['--add-dir',process.env.HOME+'/.ai-core']])if(args[args.indexOf(flag)+1]!==value)throw Error(flag);
for(const flag of ['exec','--skip-git-repo-check','--json','fixture brief'])if(!args.includes(flag))throw Error(flag);
JS
output="$HOME/.ai-core/sessions/fixture.out"
[ "$(head -n1 "$output" | jq -r .thread_id)" = fixture-thread ] || fail 'thread output'
[ "$(jq -sr '[.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text] | last' "$output")" = 'fixture final report' ] || fail 'final message output'
for part in '-p ai-core' '-m gpt-6-astra' 'model_reasoning_effort=max' '< /dev/null' '> ~/.ai-core/sessions/fixture.out'; do
  grep -qF -- "$part" "$WORK/launch" || fail "launch lacks $part"
done
# Claude's native default still names its own row and native start command.
grep -qF 'claude "Read <brief file>' "$ROOT/skills/person-in-charge/references/claude.md" || fail 'native Claude start'
awk -F'\t' '$1=="claude" && $2=="plan" && $3=="high-risk" { found=($4=="claude-fable-5-1" && $5=="xhigh") } END { exit !found }' "$ROOT/templates/.ai-core/models.tsv" || fail 'native Claude default'
REF="$ROOT/skills/person-in-charge/references/codex.md" WORK="$WORK" node <<'JS'
const fs=require('fs'),s=fs.readFileSync(process.env.REF,'utf8');
const command=s.match(/^    codex exec resume[\s\S]*?(?=\n\n)/m)[0].replace(/^    /gm,'').replaceAll('<thread id>','fixture-thread').replaceAll('<text>','continue').replaceAll('/absolute/path/to/added-directory',process.env.WORK+'/added');
fs.writeFileSync(process.env.WORK+'/resume',command+'\n');
JS
bash "$WORK/resume" > "$WORK/resume.out"
node - "$CAPTURE" "$WORK" <<'JS'
const fs=require('fs'),args=fs.readFileSync(process.argv[2],'utf8').trimEnd().split('\n'),work=process.argv[3];
for(const value of ['exec','resume','fixture-thread','--skip-git-repo-check','sandbox_workspace_write.writable_roots=["'+work+'/added"]','continue'])if(!args.includes(value))throw Error('resume lost '+value);
JS
echo 'all Codex phase commands, routing contracts, and stale-instruction mutants passed'
