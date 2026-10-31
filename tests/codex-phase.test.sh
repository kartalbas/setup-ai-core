#!/usr/bin/env bash
# Refute stale routing instructions: the sentences of the skill, its references, its briefs and the rules that a planted defect removes.
# The launch of each tool is run, with stand-ins, by tests/start-phase.test.sh.
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
contains(base+'references/codex.md','codex-sessions.tsv');
contains(base+'references/codex.md','last `agent_message`');
contains(base+'references/codex.md','--file ~/.ai-core/sessions/<session name>.out');
contains(base+'references/codex.md','as percent used against `USAGE_STOP_AT` as percent used');
contains(base+'references/claude.md','shown as percent used, with their reset times');
contains(base+'references/agy.md','`phase-model` calls `ai-core usage --tool agy --model MODEL`');
contains(base+'references/agy.md','shows it as percent used, against `USAGE_STOP_AT` as percent used');
contains(base+'references/agy.md','do not start or fall back to another tool');
contains(base+'references/agy.md','holds the conversation id only once the run has ended');
contains('skills/helper/SKILL.md','once that run has ended; the output holds it only then');
if(read('skills/helper/SKILL.md').includes('Take the id from'))throw Error('helper conversation id claim is stale');
if(read(base+'references/agy.md').includes('stands in that first answer'))throw Error('agy conversation id claim is stale');
if(read(base+'references/agy.md').includes('no command the harness reads'))throw Error('agy quota claim is stale');
if(read(base+'references/codex.md').includes('keeps the folders of its start'))throw Error('false resume folder claim');

contains('rules/80-working-style-for-agents.md','on its own because a quota ran out');
contains('rules/80-working-style-for-agents.md','every session using that limited account or model');
contains('README.md',"`ai-core tool-order claude` returns to Claude alone");
contains('templates/.ai-core/models.tsv',"Saving an order leaves the model rows unchanged");
contains('README.md','| `tool-order` | `ai-core tool-order [TOOL[,TOOL...] \\| --clear]`');
contains('README.md','| `phase-model` | `ai-core phase-model PHASE CLASS [--written-by MODEL]`');
contains('README.md','Without `--tool`, also reports the saved order, set time, per-tool start counts');
contains(base+'SKILL.md','order <saved order or not set> | selected <TOOL MODEL EFFORT>');
contains(base+'SKILL.md','ai-core phase-model plan-check <class> --written-by <actual plan or re-plan model>');
contains(base+'SKILL.md','ai-core phase-model review <class> --written-by <model that built the repair>');
contains(base+'SKILL.md','A week it names as reaching the limit is watched by whoever holds the account');

contains(base+'SKILL.md','Right after you classify a package, mechanical or not, put it on every issue of the package with the one command of both trackers');
contains(base+'SKILL.md','leave `previous` as it was, read the tracker, and run it again from the same members');
contains(base+'SKILL.md','Until a run has confirmed every member, the package is not classified and no phase that depends on it starts');
contains(base+'SKILL.md','a restart runs the command with `--member` every one of `members` and `--remove` every departure');
contains(base+'SKILL.md','| <next step> | package <OWNER/REPO#NUMBER> | members <OWNER/REPO#NUMBER>, ... | previous <OWNER/REPO#NUMBER>, ... or none');
contains(base+'briefs/coordinator.md','has `members` that differ from `previous`, the last run of `ai-core issue-package` did not confirm');
contains(base+'briefs/coordinator.md','`package`, `members` and `previous` fields are what the next coordinator labels the package from');

contains(base+'briefs/build.md',"You build it yourself, in your own tool");
contains(base+'briefs/plan.md',"Then walk each promise as the person meets it on that environment");
contains(base+'briefs/plan.md',"so the UI test proves it instead of finding it");
contains(base+'briefs/plan.md',"A defect you read in a span of the package joins the package as a criterion of the issue it touches");
contains(base+'briefs/plan-check.md',"Each gap names the issue of the package it belongs to");
contains(base+'briefs/plan-check.md',"A gap never becomes an issue of its own");
contains(base+'briefs/review.md',"A defect you meet outside the diff but in the package's files or contracts you repair too");
contains(base+'briefs/review.md',"you file no issue and put it into none: it goes to the owner, who decides whether it becomes work at all");
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
contains('rules/80-working-style-for-agents.md',"An issue carries the full case");
contains('rules/80-working-style-for-agents.md',"`review`, `ui-test` or `keeper`; a plan re-check is `plan-check`");
contains(base+'SKILL.md',"do not cover, and only through the issue keeper");
contains(base+'SKILL.md',"copy them, each with the session that wrote it, into your comment that answers that report or result there");
contains(base+'briefs/coordinator.md',"every `KEEPER round` line, every `KEEPER:` line");
contains(base+'briefs/coordinator.md',"every merge commit of a `LAND` line that no `KEEPER round` line names");
contains(base+'briefs/keeper.md',"**A landing moved the facts of an issue.**");
contains(base+'briefs/keeper.md',"(`LANDED: <repo> <merge sha> <file> <old span> -> <new span>`, `<file>` the path before the landing)");
contains(base+'briefs/keeper.md',"`Facts rewritten by the issue keeper after <merge sha>: <what changed and why>`");
contains(base+'briefs/keeper.md',"An issue's text changes only as a landing moved its facts");
contains(base+'briefs/keeper.md',"A sub-issue is a new issue too: file nothing until the owner says yes");
contains(base+'SKILL.md',"the keeper also rewrites the facts of every open issue whose named `file:line` spans the");
contains(base+'SKILL.md',"rewrites an issue only after a");
contains('rules/70-working-with-the-product-owner.md',"one that the round cannot fix goes to the project's issue keeper, which");
contains('rules/70-working-with-the-product-owner.md',"files it into what exists and asks the owner before a new issue.");
contains('rules/90-the-harness-in-a-repository.md',"it hands it to the issue keeper of that layer's project, which files it in the");
contains(base+'SKILL.md',"| landed <repo> <merge sha>, ... | <next step>");
contains(base+'briefs/keeper.md',"other than the ones the landing carries (every issue that `git -C <clone> log --format=%B <merge sha>^1..<merge sha>` names");
contains(base+'briefs/keeper.md',"Read the file as the clone's `origin/<default>` holds it");
contains(base+'briefs/keeper.md',"A line `<old file> -> <new file>` moved the whole file");
contains(base+'briefs/keeper.md',"Every `ai-core issue-*` command you run names the issue's repository");
contains(base+'SKILL.md',"line per file that diff renames, because a file renamed alone shows no hunk");
contains(base+'SKILL.md',"or a merge commit of a `LAND` line that no `KEEPER round` line names as landed, makes the issue keeper due");
contains(base+'SKILL.md',"for the `KEEPER:` lines and the landings no `KEEPER round` line has handed over");
contains(base+'briefs/plan-check.md',"KEEPER: <repo> <file:line> <state of a defect outside the section's files and contracts>, one line each | none");
contains(base+'briefs/clearing.md',"KEEPER: <repo> <file:line> <state of a defect outside the cards of the round>, one line each | none");
contains(base+'briefs/review.md',"goes under NOTES as `KEEPER: <repo> <file:line> <state>`");
contains(base+'briefs/keeper.md',"for a UI test `KEEPER: <URL> <the visible text, or what the screenshot shows>`");
contains('README.md',"One session per project files its issues, the issue keeper, the `keeper` row of `models.tsv`");
for(const tool of ['claude','codex','agy'])if(!read('templates/.ai-core/models.tsv').includes(' '+tool+' keeper * '))throw Error('models.tsv: no keeper row of '+tool);
contains(base+'SKILL.md',"goes back to `implementing`, with the SEEN text as a new acceptance criterion on that same issue");
contains(base+'SKILL.md',"A `type:bug` issue opens only for what the card's own criteria do not cover");
contains(base+'briefs/ui-test.md',"A FAIL of a card's own promise is that card's FAIL, not a new defect.");
contains(base+'briefs/ui-test.md',"Every page you open also gets one screenshot of what is visible");
contains(base+'briefs/ui-test.md',"more than one item of a menu or a tree drawn as the current one");
contains(base+'briefs/ui-test.md',"the first time you reach it");
for (const check of ['text cut off or overlapping', 'an empty or white area where content belongs', 'an element outside its frame', 'an error message on the page'])
  contains(base+'briefs/ui-test.md',check);
contains(base+'briefs/ui-test.md',"A defect you see there that no promise names is no FAIL of a card: it goes into a `KEEPER:` line");
contains(base+'briefs/ui-test.md',"add `KEEPER: <URL> <the visible text, or what the screenshot shows>` below the results");
contains(base+'briefs/ui-test.md',"For a promise, take a screenshot (`take_screenshot`, of the one element where you can) where the promise is about how something looks, or to show what a FAIL saw, and say which in its NOTES.");
if(read(base+'briefs/ui-test.md').includes('only where a promise is about how something looks'))throw Error('UI screenshots are still limited to promises about looks');
contains(base+'briefs/coordinator.md',"One defect is one issue, in the repository that owns it");
contains(base+'briefs/clearing.md',"→ testing, unless a UI test said FAIL after its `Landed on` record");
contains(base+'briefs/clearing.md',"landed, a UI test said FAIL → a build session (briefs/build.md)");
contains(base+'SKILL.md',"landed work goes to `testing` unless a UI test said FAIL after its landing");
contains('rules/80-working-style-for-agents.md',"Independent pieces are split into their own issues, each after the owner's yes, before any detail is refined, and the plan of a package checks its issues again: each issue lands whole in one package, issues that always land together become one, and a piece that a later package carries becomes its own issue once the owner says yes.");
contains(base+'briefs/plan.md',"KEEPER: re-cut split <repo>#<n>: <share and existing criteria> -> <package>");
contains(base+'briefs/plan.md',"KEEPER: re-cut merge <repo>#<n> into <repo>#<m>");
contains(base+'briefs/plan-check.md',"A re-cut line is not evidence that the work already belongs to an issue");
contains(base+'briefs/plan-check.md',"Copy the section's pending `KEEPER: re-cut` lines into the output, one line each");
contains(base+'briefs/keeper.md',"Before any write for a re-cut, match every criterion to the source issue's current body or an accepted amendment in its thread");
contains(base+'briefs/keeper.md',"If any criterion adds work no source issue held, refuse the re-cut without changing either issue");
contains(base+'briefs/keeper.md',"A `Landed part on` record does not count");
contains(base+'briefs/keeper.md',"Without that full landing record, keep its status and report `LANDING NEEDED`");
contains(base+'briefs/keeper.md',"An issue's text changes only as a landing moved its facts or a validated re-cut moves its existing criteria");
contains(base+'SKILL.md',"Before a build starts, every re-cut affecting its section must be complete");
contains(base+'SKILL.md',"landing moved the facts it names or a validated re-cut moves its existing criteria");
contains('README.md',"Every new issue, including a sub-issue and a plan issue, waits for the owner's yes");
contains('rules/80-working-style-for-agents.md',"No session creates a new issue without the owner's yes for that very issue");
contains('rules/80-working-style-for-agents.md',"a second reader on another model than the reviewer's reads only the repaired lines against the named findings before the package lands");
contains(base+'briefs/keeper.md',"A merge needs no new approval; a split creates an issue and waits for the owner's yes for that issue");
contains(base+'briefs/keeper.md',"`--asked-by` naming the owner and `--asked-in` where he approved this split");
contains(base+'briefs/coordinator.md',"ask the owner, and on his yes create it");
contains(base+'briefs/review.md',"For a review's own repair after GO, this is the head before that review's REPAIRED commits");
contains(base+'SKILL.md',"ai-core phase-model review <class> --written-by <reviewer's model>");
contains(base+'SKILL.md',"GO, and a second reader's GO on any REPAIRED commits");
for (const [file, stale] of [[base+'briefs/keeper.md', 'so it needs no yes of the owner'], [base+'briefs/keeper.md', '--found-in'], ['README.md', "The exception is a plan's `KEEPER: re-cut`"]])
  if(read(file).includes(stale))throw Error(file+': superseded approval exception: '+stale);
const handOver=['SKILL.md','briefs/plan.md','briefs/plan-check.md','briefs/review.md','briefs/ui-test.md','briefs/coordinator.md','briefs/clearing.md','briefs/build.md','briefs/keeper.md'];
for (const file of handOver)
  for (const stale of ['Left out:','`OUTSIDE:`'])
    if(read(base+file).includes(stale))throw Error(file+': the hand-over has two words: '+stale);
const files=['SKILL.md','briefs/plan.md','briefs/plan-check.md','briefs/review.md','briefs/ui-test.md','briefs/coordinator.md','briefs/clearing.md','briefs/build.md'];
for (const file of files)
  for (const stale of ['--found-in','opens one `type:bug`','stays in `testing`'])
    if(read(base+file).includes(stale))throw Error(file+': a failed UI test still opens an issue: '+stale);
for (const [file,stale] of [['../../rules/70-working-with-the-product-owner.md',"gets an issue only with the owner's yes"],['../../rules/90-the-harness-in-a-repository.md',"it opens an issue in the repository of that layer"],['briefs/keeper.md',"never rewrite an issue"],['SKILL.md',"rewrites no issue"],['briefs/keeper.md','--asked-by {{the owner\'s login}} --asked-in "the owner\'s'],['briefs/keeper.md','Read the file at the head of the clone'],['briefs/keeper.md','other than the ones the merge commit names']])
  if(read(base+file).includes(stale))throw Error(file+': the keeper text of round 1 stands: '+stale);
JS
node "$WORK/check.mjs" "$ROOT" || fail 'phase routing contract'
cp -R "$ROOT/skills" "$WORK/skills"
mkdir -p "$WORK/rules" "$WORK/templates/.ai-core"
cp "$ROOT/rules/70-working-with-the-product-owner.md" "$ROOT/rules/80-working-style-for-agents.md" "$ROOT/rules/90-the-harness-in-a-repository.md" "$WORK/rules/"
cp "$ROOT/templates/.ai-core/models.tsv" "$WORK/templates/.ai-core/"
cp "$ROOT/README.md" "$WORK/"
for pair in 'SKILL.md|Until a run has confirmed every member, the package is not classified' 'SKILL.md|leave `previous` as it was' 'SKILL.md|and `--remove` every departure' 'briefs/coordinator.md|differ from `previous`' 'briefs/coordinator.md|are what the next coordinator labels the package from' 'references/codex.md|including Claude Code' 'SKILL.md|order takes precedence and survives restarts and init' 'SKILL.md|With no saved order it keeps native-tool selection' 'references/codex.md|last `agent_message`' 'references/codex.md|--file ~/.ai-core/sessions/<session name>.out' 'references/codex.md|as percent used against' 'references/claude.md|shown as percent used, with their reset times' 'references/agy.md|`phase-model` calls' 'references/agy.md|shows it as percent used, against' 'references/agy.md|do not start or fall back to another tool' 'briefs/plan.md|so the UI test proves it instead of finding it' 'briefs/plan.md|joins the package as a criterion of the issue it touches' 'briefs/plan-check.md|A gap never becomes an issue of its own' 'briefs/review.md|you file no issue and put it into none: it goes to the owner' 'briefs/plan.md|and you file no issue: the project'"'"'s issue keeper files it into what exists' 'briefs/plan-check.md|the project'"'"'s issue keeper files it into what exists' 'briefs/build.md|You file no issue, because the project'"'"'s issue keeper files into what exists' 'briefs/ui-test.md|and the project'"'"'s issue keeper files it into what exists' 'briefs/keeper.md|Never file a new issue or a new epic without the owner'"'"'s yes' 'SKILL.md|ai-core phase-model keeper normal-hard' 'briefs/review.md|never into FINDINGS' 'SKILL.md|goes back to `implementing`' 'briefs/ui-test.md|not a new defect' 'briefs/coordinator.md|One defect is one issue' 'briefs/clearing.md|unless a UI test said FAIL after its `Landed on` record' 'briefs/clearing.md|a build session (briefs/build.md) from the issue' 'SKILL.md|unless a UI test said FAIL after its landing' 'SKILL.md|is watched by whoever holds the account' 'SKILL.md|do not cover, and only through the issue keeper' 'SKILL.md|into your comment that answers that report or result there' 'briefs/coordinator.md|every `KEEPER round` line, every `KEEPER:` line' 'briefs/coordinator.md|every merge commit of a `LAND` line that no `KEEPER round` line names' 'briefs/keeper.md|**A landing moved the facts of an issue.**' 'briefs/keeper.md|Facts rewritten by the issue keeper after' 'briefs/keeper.md|An issue'"'"'s text changes only as a landing moved its facts' 'briefs/keeper.md|A sub-issue is a new issue too' 'SKILL.md|the keeper also rewrites the facts of every open issue' 'SKILL.md|| landed <repo> <merge sha>, ... | <next step>' 'briefs/keeper.md|other than the ones the landing carries' 'briefs/keeper.md|Read the file as the clone'"'"'s `origin/<default>` holds it' 'briefs/keeper.md|A line `<old file> -> <new file>` moved the whole file' 'briefs/keeper.md|Every `ai-core issue-*` command you run names the issue'"'"'s repository' 'SKILL.md|because a file renamed alone shows no hunk' 'SKILL.md|names as landed, makes the issue keeper due' 'SKILL.md|for the `KEEPER:` lines and the landings no' 'briefs/plan-check.md|outside the section'"'"'s files and contracts>, one line each' 'briefs/clearing.md|outside the cards of the round>' 'briefs/review.md|`KEEPER: <repo> <file:line> <state>`' 'briefs/keeper.md|for a UI test `KEEPER: <URL> <the visible text, or what the screenshot shows>`'; do
  file="${pair%%|*}"; phrase="${pair#*|}"
  FILE="$WORK/skills/person-in-charge/$file" PHRASE="$phrase" node -e 'const fs=require("fs"),p=process.env.FILE,s=fs.readFileSync(p,"utf8");fs.writeFileSync(p,s.replace(new RegExp(process.env.PHRASE.split(/\s+/).map(x=>x.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")).join("\\s+")),"stale instruction"))'
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "stale instruction escaped: $phrase"; fi
  cp "$ROOT/skills/person-in-charge/$file" "$WORK/skills/person-in-charge/$file"
done
# Every page gets a visual check; incidental defects and failed promises keep their separate routes.
visual_cases=0
for pair in \
  'briefs/ui-test.md|Every page you open also gets one screenshot of what is visible' \
  'briefs/ui-test.md|the first time you reach it' \
  'briefs/ui-test.md|more than one item of a menu or a tree drawn as the current one' \
  'briefs/ui-test.md|text cut off or overlapping' \
  'briefs/ui-test.md|an empty or white area where content belongs' \
  'briefs/ui-test.md|an element outside its frame' \
  'briefs/ui-test.md|an error message on the page' \
  'briefs/ui-test.md|A defect you see there that no promise names' \
  'briefs/ui-test.md|it goes into a `KEEPER:` line' \
  'briefs/ui-test.md|the visible text, or what the screenshot shows' \
  'briefs/ui-test.md|For a promise, take a screenshot' \
  'briefs/keeper.md|the visible text, or what the screenshot shows'; do
  file="${pair%%|*}"; phrase="${pair#*|}"
  FILE="$WORK/skills/person-in-charge/$file" PHRASE="$phrase" node -e 'const fs=require("fs"),p=process.env.FILE,s=fs.readFileSync(p,"utf8"),r=new RegExp(process.env.PHRASE.split(/\s+/).map(x=>x.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")).join("\\s+"));if(!r.test(s))throw Error("mutation found no instruction");fs.writeFileSync(p,s.replace(r,"stale instruction"))'
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "visual check defect escaped: $phrase"; fi
  cp "$ROOT/skills/person-in-charge/$file" "$WORK/skills/person-in-charge/$file"
  visual_cases=$((visual_cases + 1))
done
printf '\nTake a screenshot only where a promise is about how something looks.\n' >> "$WORK/skills/person-in-charge/briefs/ui-test.md"
if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail 'the old screenshot restriction escaped'; fi
cp "$ROOT/skills/person-in-charge/briefs/ui-test.md" "$WORK/skills/person-in-charge/briefs/ui-test.md"
visual_cases=$((visual_cases + 1))
node "$WORK/check.mjs" "$WORK" || fail 'restored visual check instructions'
echo "  visual check instructions: $visual_cases planted defects refused; restored instructions accepted"
# A re-cut cannot grant new scope or send a partial landing to proof.
for pair in 'briefs/keeper.md|A sub-issue is a new issue too' 'briefs/plan.md|<share and existing criteria>' 'briefs/plan.md|KEEPER: re-cut merge' 'briefs/plan-check.md|A re-cut line is not evidence' 'briefs/plan-check.md|Copy the section'"'"'s pending `KEEPER: re-cut` lines' 'briefs/keeper.md|Before any write for a re-cut, match every criterion' 'briefs/keeper.md|If any criterion adds work no source issue held' 'briefs/keeper.md|A `Landed part on` record does not count' 'briefs/keeper.md|Without that full landing record, keep its status' 'briefs/keeper.md|or a validated re-cut moves its existing criteria' 'SKILL.md|Before a build starts, every re-cut affecting its section must be complete' 'SKILL.md|or a validated re-cut moves its existing criteria'; do
  file="${pair%%|*}"; phrase="${pair#*|}"
  FILE="$WORK/skills/person-in-charge/$file" PHRASE="$phrase" node -e 'const fs=require("fs"),p=process.env.FILE,s=fs.readFileSync(p,"utf8"),r=new RegExp(process.env.PHRASE.split(/\s+/).map(x=>x.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")).join("\\s+"),"g");if(!r.test(s))throw Error("mutation found no instruction");fs.writeFileSync(p,s.replace(r,"stale instruction"))'
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "re-cut defect escaped: $phrase"; fi
  cp "$ROOT/skills/person-in-charge/$file" "$WORK/skills/person-in-charge/$file"
done
FILE="$WORK/rules/80-working-style-for-agents.md" node -e 'const fs=require("fs"),p=process.env.FILE;fs.writeFileSync(p,fs.readFileSync(p,"utf8").replace("each issue lands whole in one package", "each issue may span packages"))'
if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail 'the changed rule 80 sentence escaped'; fi
cp "$ROOT/rules/80-working-style-for-agents.md" "$WORK/rules/80-working-style-for-agents.md"
FILE="$WORK/README.md" node -e 'const fs=require("fs"),p=process.env.FILE;fs.writeFileSync(p,fs.readFileSync(p,"utf8").replace("Every new issue, including a sub-issue\n    and a plan issue, waits", "Every new issue skips approval and never waits"))'
if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail 'the changed readme permission escaped'; fi
cp "$ROOT/README.md" "$WORK/README.md"
node "$WORK/check.mjs" "$WORK" || fail 'restored re-cut instructions'
echo '  re-cut instructions: 14 planted defects refused; restored instructions accepted'
# Every new issue needs approval, and a review's repair needs its own independent reader.
policy_cases=0
for pair in \
  'rules/80-working-style-for-agents.md|No session creates a new issue without the owner' \
  'rules/80-working-style-for-agents.md|a second reader on another model than' \
  'skills/person-in-charge/briefs/keeper.md|A merge needs no new approval; a split creates an issue' \
  'skills/person-in-charge/briefs/keeper.md|where he approved this split' \
  'skills/person-in-charge/briefs/coordinator.md|ask the owner, and on his yes create it' \
  'skills/person-in-charge/briefs/review.md|For a review' \
  'skills/person-in-charge/SKILL.md|--written-by <reviewer' \
  'skills/person-in-charge/SKILL.md|GO, and a second reader'; do
  file="${pair%%|*}"; phrase="${pair#*|}"
  FILE="$WORK/$file" PHRASE="$phrase" node -e 'const fs=require("fs"),p=process.env.FILE,s=fs.readFileSync(p,"utf8"),r=new RegExp(process.env.PHRASE.split(/\s+/).map(x=>x.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")).join("\\s+"));if(!r.test(s))throw Error("mutation found no instruction");fs.writeFileSync(p,s.replace(r,"stale instruction"))'
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "approval or repair check escaped: $phrase"; fi
  cp "$ROOT/$file" "$WORK/$file"; policy_cases=$((policy_cases + 1))
done
for pair in 'skills/person-in-charge/briefs/keeper.md|so it needs no yes of the owner' 'skills/person-in-charge/briefs/keeper.md|--found-in' 'README.md|The exception is a plan'"'"'s `KEEPER: re-cut`'; do
  file="${pair%%|*}"; printf '\n%s\n' "${pair#*|}" >> "$WORK/$file"
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "approval exception escaped: ${pair#*|}"; fi
  cp "$ROOT/$file" "$WORK/$file"; policy_cases=$((policy_cases + 1))
done
node "$WORK/check.mjs" "$WORK" || fail 'restored approval and repair instructions'
echo "  approval and repair instructions: $policy_cases planted defects refused; restored instructions accepted"
# A stale sentence planted in any file of the check goes red; the restored tree stays green.
for file in SKILL.md briefs/plan.md briefs/plan-check.md briefs/review.md briefs/ui-test.md briefs/coordinator.md briefs/clearing.md briefs/build.md; do
  for stale in '--found-in' 'opens one `type:bug`' 'stays in `testing`'; do
    printf '\n%s\n' "$stale" >> "$WORK/skills/person-in-charge/$file"
    if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "stale sentence escaped in $file: $stale"; fi
    cp "$ROOT/skills/person-in-charge/$file" "$WORK/skills/person-in-charge/$file"
  done
done
# The keeper texts of round 1 planted go red: the forbidden rewrite and the claim that the owner asked for a sub-issue.
for pair in 'briefs/keeper.md|never rewrite an issue' 'SKILL.md|rewrites no issue' 'briefs/keeper.md|--asked-by {{the owner'"'"'s login}} --asked-in "the owner'"'"'s' 'briefs/keeper.md|Read the file at the head of the clone' 'briefs/keeper.md|other than the ones the merge commit names'; do
  printf '\n%s\n' "${pair#*|}" >> "$WORK/skills/person-in-charge/${pair%%|*}"
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "a keeper text of round 1 escaped: ${pair#*|}"; fi
  cp "$ROOT/skills/person-in-charge/${pair%%|*}" "$WORK/skills/person-in-charge/${pair%%|*}"
done
# The two rule sentences as they stood before the keeper planted go red.
for pair in '70-working-with-the-product-owner.md|one that the round cannot fix gets an issue only with the owner'"'"'s yes;' '90-the-harness-in-a-repository.md|it opens an issue in the repository of that layer'; do
  printf '\n%s\n' "${pair#*|}" >> "$WORK/rules/${pair%%|*}"
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "a rule text before the keeper escaped: ${pair#*|}"; fi
  cp "$ROOT/rules/${pair%%|*}" "$WORK/rules/${pair%%|*}"
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
# The rule's text as it stood before its two repairs goes red: "It" that reads as the keeper, and a phase list without `keeper`.
for pair in 'An issue carries the full case|It carries the full case' '`review`, `ui-test` or `keeper`;|`review` or `ui-test`;'; do
  FILE="$WORK/rules/80-working-style-for-agents.md" PHRASE="${pair%%|*}" WITH="${pair#*|}" node -e 'const fs=require("fs"),p=process.env.FILE,s=fs.readFileSync(p,"utf8"),r=new RegExp(process.env.PHRASE.split(/\s+/).map(x=>x.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")).join("\\s+"));if(!r.test(s))process.exit(3);fs.writeFileSync(p,s.replace(r,process.env.WITH))' || fail "rule phrase not found to plant: ${pair%%|*}"
  if node "$WORK/check.mjs" "$WORK" > "$WORK/mutant.log" 2>&1; then fail "the rule's text before its repair passed: ${pair#*|}"; fi
  cp "$ROOT/rules/80-working-style-for-agents.md" "$WORK/rules/"
done
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
# THE GUARD OF THE PLAN ISSUE is extracted from SKILL.md and run against a stand-in ai-core that answers issue-thread with a
# thread of N comments, with a failed read, or with an answer that is no thread. 2499 comments continue, 2500 refuse; a read
# that fails or has no comments list refuses too, because it is no zero. The thread is never printed and no file stays.
extract_guard() {  # extract_guard <SKILL.md>: the bash block that defines plan_issue_has_room
  awk '/^ *```bash$/ { inside = 1; block = ""; next }
       /^ *```$/ { if (inside && index(block, "plan_issue_has_room()")) { printf "%s", block; found = 1; exit } inside = 0; next }
       inside { sub(/^   /, ""); block = block $0 "\n" }
       END { exit found ? 0 : 1 }' "$1"
}
GUARD="$(extract_guard "$ROOT/skills/person-in-charge/SKILL.md")" || fail 'SKILL.md holds no plan_issue_has_room guard'
mkdir -p "$WORK/guard-bin" "$WORK/guard-tmp"
cat > "$WORK/guard-bin/ai-core" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2 $3 $4" = "issue-thread example-org/plans 7 --json" ] || { echo "unexpected call: $*" >&2; exit 9; }
[ "${GUARD_THREAD:-}" != FAIL ] || { echo 'error: cannot read the thread' >&2; exit 1; }
cat "$GUARD_THREAD"
EOF
chmod +x "$WORK/guard-bin/ai-core"
guard_run() {  # guard_run <guard code> <thread file or FAIL>: the status in $guard_rc, stdout and stderr in $guard_out and $guard_err
  guard_rc=0
  GUARD_THREAD="$2" PATH="$WORK/guard-bin:$PATH" TMPDIR="$WORK/guard-tmp" bash -c "$1"$'\n''plan_issue_has_room example-org/plans 7' > "$WORK/guard-out" 2> "$WORK/guard-err" || guard_rc=$?
  guard_out="$(cat "$WORK/guard-out")"; guard_err="$(cat "$WORK/guard-err")"
}
thread_of() { jq -n --argjson n "$1" '{issue: {number: 7}, comments: [range(0; $n) | {body: "a comment"}]}' > "$WORK/guard-thread-$1"; echo "$WORK/guard-thread-$1"; }
for n in 0 2499; do
  guard_run "$GUARD" "$(thread_of $n)"
  [ "$guard_rc" = 0 ] && [ -z "$guard_out$guard_err" ] || fail "the guard refused a plan issue of $n comments: $guard_rc $guard_err"
done
for n in 2500 2501; do
  guard_run "$GUARD" "$(thread_of $n)"
  [ "$guard_rc" = 1 ] && grep -q "preflight refusal: example-org/plans#7 holds $n comments" <<< "$guard_err" && grep -q 'HTTP 403' <<< "$guard_err" || fail "the guard did not refuse $n comments: $guard_rc $guard_err"
  [ -z "$guard_out" ] || fail "the guard printed the thread: $guard_out"
done
printf 'not json at all\n' > "$WORK/guard-bad"; printf '{"issue":{}}\n' > "$WORK/guard-nokey"; printf '{"comments":"many"}\n' > "$WORK/guard-string"; printf '' > "$WORK/guard-empty"
for unreadable in FAIL "$WORK/guard-bad" "$WORK/guard-nokey" "$WORK/guard-string" "$WORK/guard-empty"; do
  guard_run "$GUARD" "$unreadable"
  [ "$guard_rc" = 1 ] && grep -q 'comment count is not known' <<< "$guard_err" || fail "the guard took a read that is no thread ($unreadable) for room: $guard_rc $guard_err"
done
[ -z "$(ls -A "$WORK/guard-tmp")" ] || fail "the guard left a file behind: $(ls "$WORK/guard-tmp")"
# planted: the limit moved up, a failed read taken for zero comments, and no guard at all; each goes red where the real one is green
planted="${GUARD/-lt 2500/-lt 9999}"; [ "$planted" != "$GUARD" ] || fail 'the planted limit equals the guard'
guard_run "$planted" "$(thread_of 2500)"; [ "$guard_rc" = 0 ] || fail 'planted: a moved limit should accept 2500 comments'
planted="${GUARD/echo \"preflight refusal: the thread/return 0; echo \"preflight refusal: the thread}"; [ "$planted" != "$GUARD" ] || fail 'the planted zero equals the guard'
guard_run "$planted" FAIL; [ "$guard_rc" = 0 ] || fail 'planted: a failed read taken for zero should continue'
guard_run 'plan_issue_has_room() { return 0; }' "$(thread_of 2500)"; [ "$guard_rc" = 0 ] || fail 'planted: no guard should continue'
echo "  the plan issue guard of SKILL.md, run as extracted: 2499 continue, 2500 refuse, no read is no zero; planted: a moved limit, a failed read as zero and no guard each continue"
