#!/usr/bin/env bash
# issue-package on GitHub: the label of a package on every issue of it, its archival with the last member, and what it says
# where a step fails.
#
#   bash tests/issue-package.test.sh
#
# NOTHING REACHES github.com. tests/gh-rest-fake.mjs stands in for gh and keeps the labels and the issues of four repositories
# in a file, so what is judged is the state it is left in and never the words the script printed. The command is run as the
# coordinator runs it: tests/package-workflow.mjs reads it out of skills/person-in-charge/SKILL.md, fills in the issues, and
# bin/ai-core runs it. A command of the test's own would prove nothing about the skill.
#
# THE PLANTED DEFECTS, each replayed so it is shown RED: a package whose second repository was skipped; archival once any
# member is complete, where only the last member's completion archives; a GitHub that ignores the archival and answers
# that the label is active; a skill whose command drifted. THE INNOCENT CASES stay green beside them: the issue outside the
# package, the package that is not complete, the label of the package's own first issue that was archived.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AI_CORE_HOME="$WORK/core" GH_CACHE_DIRECTORY="$WORK/cache" AI_CORE_UPDATE_CHECK=never
export GH_REST_STATE="$WORK/state"
mkdir -p "$HOME" "$AI_CORE_HOME" "$GH_REST_STATE" "$WORK/bin" "$WORK/project"
git init -q "$WORK/project"
SKILL="$ROOT/skills/person-in-charge/SKILL.md"
failed=0

check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; failed=$((failed + 1)); fi
}
matches() {  # matches <name> <regular expression> <text>
  if grep -Eq -- "$2" <<< "$3"; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected to match: $2"; echo "       actual: [$3]"; failed=$((failed + 1)); fi
}

# gh is the stand-in, and ai-core runs the harness under test
printf '#!/bin/sh\nexec node "${GH_FAKE_SCRIPT:-%s/tests/gh-rest-fake.mjs}" "$@"\n' "$ROOT" > "$WORK/bin/gh"
printf '#!/bin/sh\nexec bash "${ROOT_UNDER_TEST:-%s}/bin/ai-core" "$@"\n' "$ROOT" > "$WORK/bin/ai-core"
chmod +x "$WORK/bin/gh" "$WORK/bin/ai-core"
export PATH="$WORK/bin:$PATH"

# Two organizations: three repositories in the first, one in the second, every issue open.
seed_world() {  # seed_world [the most labels a page of the tracker holds]
  rm -f "$GH_REST_STATE"/calls.log "$GH_REST_STATE"/writes.log "$GH_REST_STATE"/lock "$GH_REST_STATE"/barrier-*
  jq -n --argjson page "${1:-100}" '
    def labels: [{name: "type:feature", color: "a2eeef", description: "A feature", archived_at: null, archived_by: null},
                 {name: "area:tooling", color: "1d76db", description: "Tooling", archived_at: null, archived_by: null}];
    def issues($n): [range(1; $n + 1)] | map({key: tostring, value: {title: "Issue \(.)", state: "open", state_reason: null, labels: ["type:feature", "area:tooling"]}}) | from_entries;
    {pageSize: $page, repos: {
      "example-org/shop": {labels: labels, issues: issues(8)}, "example-org/api": {labels: labels, issues: issues(8)},
      "example-org/plans": {labels: labels, issues: issues(9)}, "other-org/lib": {labels: labels, issues: issues(4)}},
     fail: [], barriers: []}' > "$GH_REST_STATE/github.json"
}
state() { jq -r "$1" "$GH_REST_STATE/github.json"; }
patch_state() { jq "$1" "$GH_REST_STATE/github.json" > "$GH_REST_STATE/github.json.new" && mv "$GH_REST_STATE/github.json.new" "$GH_REST_STATE/github.json"; }
plant_failure() { patch_state ".fail += [$1]"; }
writes() { if [ -f "$GH_REST_STATE/writes.log" ]; then wc -l < "$GH_REST_STATE/writes.log" | tr -d ' '; else echo 0; fi; }
labels_of() {  # labels_of <repo> <number>: the labels of the issue, sorted, on one line
  jq -r --arg r "$1" --arg n "$2" '.repos[$r].issues[$n].labels | sort | join(" ")' "$GH_REST_STATE/github.json"
}
package_labels_of() { labels_of "$1" "$2" | tr ' ' '\n' | grep '^package/' | paste -sd' ' - || true; }
without_package() { printf '%s\n' "$1" | tr ' ' '\n' | grep -v '^package/' | paste -sd' ' - || true; }
label_count() {  # label_count <repo> <name>: how many labels of that name the repository holds
  jq -r --arg r "$1" --arg n "$2" '[.repos[$r].labels[] | select(.name == $n)] | length' "$GH_REST_STATE/github.json"
}
label_archived() {  # label_archived <repo> <name>: true, false, or "none"
  jq -r --arg r "$1" --arg n "$2" '[.repos[$r].labels[] | select(.name == $n)][0] | if . == null then "none" else (.archived_at != null | tostring) end' "$GH_REST_STATE/github.json"
}
uri() { jq -rn --arg v "$1" '$v | @uri'; }
# the filter of the tracker, every issue state: the numbers of a repository that carry the label
filter_of() {  # filter_of <repo> <name>
  gh api "repos/$1/issues?labels=$(uri "$2")&state=all" | jq -r '.[].number' | sort -n | paste -sd' ' -
}
# every repository's filter as repository#number, sorted
filter_everywhere() {  # filter_everywhere <name>
  local repo n
  for repo in example-org/shop example-org/api example-org/plans other-org/lib; do
    for n in $(filter_of "$repo" "$1"); do echo "$repo#$n"; done
  done | sort | paste -sd' ' -
}
NAME='package/shop#5'
SHOP5=example-org/shop#5
API7=example-org/api#7
LIB4=other-org/lib#4
sorted() { printf '%s\n' "$@" | sort | paste -sd' ' -; }

# the state a package must be left in: the filters list exactly the members, each carries this one package label, and each
# repository with a member holds one label of the name, archived or active as asked ("any" asks nothing)
package_state() {  # package_state <name> <archived: true | false | any> <member>...
  local name="$1" archived="$2" member repo problems="" listed
  shift 2
  listed="$(filter_everywhere "$name")"
  [ "$listed" = "$(sorted "$@")" ] || problems="$problems filter: [$listed];"
  for member in "$@"; do
    repo="${member%#*}"
    [ "$(package_labels_of "$repo" "${member##*#}")" = "$name" ] || problems="$problems $member carries [$(package_labels_of "$repo" "${member##*#}")];"
    [ "$(label_count "$repo" "$name")" = 1 ] || problems="$problems $repo holds $(label_count "$repo" "$name") labels;"
    [ "$archived" = any ] || [ "$(label_archived "$repo" "$name")" = "$archived" ] || problems="$problems $repo archived=$(label_archived "$repo" "$name");"
  done
  echo "${problems:-fine}"
}

flags() {  # flags <members> <removals>
  local ref
  for ref in $1; do printf -- '--member %s ' "$ref"; done
  for ref in ${2:-}; do printf -- '--remove %s ' "$ref"; done
}
# package <anchor> <members> [<removals>]: the skill's command, filled in, run; rc, out and err are what it left
package() {
  local command
  command="$(node "$ROOT/tests/package-workflow.mjs" "${SKILL_UNDER_TEST:-$SKILL}" "$1" $(flags "$2" "${3:-}") 2>&1)" || { rc=99; out=""; err="$command"; return 0; }
  rc=0
  ( cd "$WORK/project" && bash -c "$command" ) > "$WORK/out" 2> "$WORK/err" || rc=$?
  out="$(cat "$WORK/out")"; err="$(cat "$WORK/err")"
}
# the completion path of the tracker and its reopening, as lib/github/tracker.sh has them
close_issue() { ( . "$ROOT/lib/tracker.sh"; issue_close "$1" "$2" "${3:-completed}" ); }
reopen_issue() { ( . "$ROOT/lib/tracker.sh"; issue_reopen "$1" "$2" ); }

echo "== classification: one label on every member of two repositories, nothing on the others"
seed_world
outside="$(labels_of example-org/shop 6)"; plan="$(labels_of example-org/plans 9)"; before="$(labels_of example-org/shop 5)"
package example-org/shop#5 "$SHOP5 $API7"
check "the command succeeds" 0 "$rc"
matches "it says how many members it confirmed" 'package/shop#5: 2 members confirmed, 0 departures confirmed, 0 of 2 members complete' "$out"
check "the filters list exactly the members, one label of the name in each repository, active" fine "$(package_state "$NAME" false "$SHOP5" "$API7")"
check "the filter of the first repository lists its member" 5 "$(filter_of example-org/shop "$NAME")"
check "the filter of the second repository lists its member" 7 "$(filter_of example-org/api "$NAME")"
check "the issue outside the package is as it was (innocent)" "$outside" "$(labels_of example-org/shop 6)"
check "the plan issue in a third repository is as it was" "$plan" "$(labels_of example-org/plans 9)"
check "the type and area labels of a member stay" "$before" "$(without_package "$(labels_of example-org/shop 5)")"
check "the label's description names the first issue" "Package anchored at example-org/shop#5" "$(jq -r '.repos["example-org/shop"].labels[] | select(.name == "package/shop#5") | .description' "$GH_REST_STATE/github.json")"

echo "== the oracle goes red where the second repository was skipped (planted), and green for the issue outside (innocent)"
seed_world
package example-org/shop#5 "$SHOP5"
matches "a package with its second repository skipped is told apart" 'filter: \[example-org/shop#5\]; example-org/api#7 carries \[\];' "$(package_state "$NAME" any "$SHOP5" "$API7")"
check "the issue outside carries no package label" "" "$(package_labels_of example-org/shop 6)"
SKIPPED="$WORK/skipped"; mkdir -p "$SKIPPED"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/skills" "$ROOT/VERSION" "$SKIPPED/"
sed -i.bak 's/done <<< "$(for ref in \(.*\) | sort -f -u)"/done <<< "$(for ref in \1 | sort -f -u | head -n 1)"/' "$SKIPPED/bin/issue-package.sh"; rm -f "$SKIPPED/bin/issue-package.sh.bak"
cmp -s "$ROOT/bin/issue-package.sh" "$SKIPPED/bin/issue-package.sh" && { echo "  FAIL the plant did not take: scopes are not cut to one"; failed=$((failed + 1)); }
seed_world
ROOT_UNDER_TEST="$SKIPPED" package example-org/shop#5 "$SHOP5 $API7"
matches "the harness that skips a repository is caught by the oracle" 'example-org/shop#5 carries \[\]' "$(package_state "$NAME" any "$SHOP5" "$API7")"

echo "== issues of one number in different repositories, and a reordered member list"
seed_world
package example-org/shop#5 "$SHOP5 example-org/api#5"
check "both carry it and neither neighbour does" fine "$(package_state "$NAME" false "$SHOP5" example-org/api#5)"
check "the neighbours of the same numbers are free" "" "$(package_labels_of example-org/api 6)$(package_labels_of example-org/shop 6)"
seed_world
package example-org/shop#5 "$API7 $SHOP5"
check "the label is named after the first issue whatever the order" fine "$(package_state "$NAME" false "$SHOP5" "$API7")"
check "no label of the first member of the list was made" 0 "$(label_count example-org/api 'package/api#7')"

echo "== membership: a later member, a departure by the previous membership, a move to another package"
seed_world
package example-org/shop#5 "$SHOP5 $API7"
package example-org/shop#5 "$SHOP5 $API7 example-org/shop#8"
check "the later member carries it" fine "$(package_state "$NAME" false "$SHOP5" "$API7" example-org/shop#8)"
api_before="$(without_package "$(labels_of example-org/api 7)")"
package example-org/shop#5 "$SHOP5 example-org/shop#8" "$API7"
check "the departure lost it and the others keep it" fine "$(package_state "$NAME" false "$SHOP5" example-org/shop#8)"
check "the departure kept its other labels" "$api_before" "$(labels_of example-org/api 7)"
package example-org/api#2 "example-org/api#2 example-org/shop#8"
check "a member moved to another package carries only that package's label" "package/api#2" "$(package_labels_of example-org/shop 8)"
package example-org/shop#5 "$SHOP5" example-org/shop#8
check "an old departure does not take the new package's label off" "package/api#2" "$(package_labels_of example-org/shop 8)"
check "the first package is its own member only" "5" "$(filter_of example-org/shop "$NAME")"

echo "== a restart from the recorded PHASE line, the plan issue elsewhere, and a second run writes nothing"
seed_world
package example-org/shop#5 "$SHOP5 $API7 example-org/shop#8"
phase="PHASE area: build | you | order not set | selected claude m high | plans 1 | reviews 0 | context fit | next | package $SHOP5 | members $SHOP5, $API7, $LIB4 | previous $SHOP5, $API7, example-org/shop#8"
field() { printf '%s\n' "$phase" | awk -F' [|] ' -v key="$1" '{ for (i = 1; i <= NF; i++) if (index($i, key " ") == 1) print substr($i, length(key) + 2) }' | sed 's/, / /g'; }
recorded_members="$(field members)"; recorded_previous="$(field previous)"
departures=""
for ref in $recorded_previous; do case " $recorded_members " in *" $ref "*) ;; *) departures="$departures $ref" ;; esac; done
check "the departure is the previous member that is no member now" "example-org/shop#8" "$(echo $departures)"
package "$(field package)" "$recorded_members" "$departures"
check "the restart left the recorded membership" fine "$(package_state "$NAME" false "$SHOP5" "$API7" "$LIB4")"
check "the departure lost it" "" "$(package_labels_of example-org/shop 8)"
check "the plan issue is untouched" "" "$(package_labels_of example-org/plans 9)"
count="$(writes)"
package "$(field package)" "$recorded_members" "$departures"
check "the second run succeeds" 0 "$rc"
check "the second run writes nothing" "$count" "$(writes)"

echo "== the first issue leaves the package, and its label is still its"
seed_world
package example-org/shop#5 "$SHOP5 $API7"
package example-org/shop#5 "$API7 example-org/api#2" "$SHOP5"
check "the label keeps the name of the first issue" fine "$(package_state "$NAME" false "$API7" example-org/api#2)"
check "the first issue lost it" "" "$(package_labels_of example-org/shop 5)"

echo "== refused before the first write"
seed_world
patch_state '.repos["example-org/api"].labels += [{name: "package/shop#5", color: "5319e7", description: "Package anchored at other-org/shop#5", archived_at: null, archived_by: null}]'
package example-org/shop#5 "$SHOP5 $API7"
check "a label of the name that names another first issue is refused" 1 "$rc"
matches "and both first issues are named" 'names the anchor other-org/shop#5.*anchored at example-org/shop#5' "$err"
check "nothing was written" 0 "$(writes)"
seed_world
patch_state '.repos["example-org/shop"].labels += [{name: "PACKAGE/SHOP#5", color: "5319e7", description: "no anchor here", archived_at: null, archived_by: null}]'
package example-org/shop#5 "$SHOP5"
matches "a label of the name, in other case, that names no anchor is refused" 'names no anchor' "$err"
check "and nothing was written" 0 "$(writes)"
seed_world
package example-org/shop#5 shop#5; check "a reference without its owner" 1 "$rc"
package example-org/shop#5 "$SHOP5 $API7" "$API7"; check "a member that is also a departure" 1 "$rc"
package example-org/shop#5 "$SHOP5 $SHOP5"; check "a member named twice" 1 "$rc"
package example-org/shop#5 "$SHOP5 example-org/api#99"; check "a member that is no issue" 1 "$rc"
matches "names it" 'example-org/api#99|HTTP 404|Not Found' "$err"
plant_failure '{"match": "GET repos/example-org/api/labels", "status": 500, "message": "Server Error"}'
package example-org/shop#5 "$SHOP5 $API7"; check "a repository whose labels cannot be read" 1 "$rc"
check "no write happened in any of them" 0 "$(writes)"
check "no label was made" 0 "$(label_count example-org/shop "$NAME")"

echo "== the label of the package's own first issue, archived, is reused (innocent)"
seed_world
patch_state '.repos["example-org/shop"].labels += [{name: "package/shop#5", color: "5319e7", description: "Package anchored at example-org/shop#5", archived_at: "2026-01-01T00:00:00Z", archived_by: {login: "x"}}]'
package example-org/shop#5 "$SHOP5 $API7"
check "it succeeds" 0 "$rc"
check "the one label of the repository is active again, and no second one was made" "1 false" "$(label_count example-org/shop "$NAME") $(label_archived example-org/shop "$NAME")"

echo "== ordinary labels of the taxonomy keep behaving, and a package label stays"
seed_world
package example-org/shop#5 "$SHOP5 $API7"
( cd "$WORK/project" && bash "$ROOT/bin/issue-label.sh" example-org/shop 5 --add area:installation --remove area:tooling ) > /dev/null 2>&1
check "the labels of the taxonomy changed and the package label stayed" "area:installation package/shop#5 type:feature" "$(labels_of example-org/shop 5)"

echo "== more than one page of labels: a later page is read, a failed page is an error"
seed_world 5
patch_state '.repos["example-org/shop"].labels += [range(0; 12) | {name: "filler\(.)", color: "ededed", description: "", archived_at: null, archived_by: null}]'
package example-org/shop#5 "$SHOP5"
check "the label stands behind the first page" true "$(jq -r '[.repos["example-org/shop"].labels | to_entries[] | select(.value.name == "package/shop#5") | .key >= 5] | any' "$GH_REST_STATE/github.json")"
posts="$(grep -c '^POST repos/example-org/shop/labels$' "$GH_REST_STATE/writes.log")"
package example-org/shop#5 "$SHOP5 example-org/shop#8"
check "the label is found on its later page and reused, so it was made once" "1 1" "$posts $(grep -c '^POST repos/example-org/shop/labels$' "$GH_REST_STATE/writes.log")"
check "and the package is whole" fine "$(package_state "$NAME" false "$SHOP5" example-org/shop#8)"
plant_failure '{"match": "GET repos/example-org/shop/labels", "page": 3, "status": 500, "message": "Server Error"}'
count="$(writes)"
package example-org/shop#5 "$SHOP5 example-org/shop#8 example-org/shop#7"
check "a page that cannot be read fails the run" 1 "$rc"
check "and writes nothing, as it does not take the label for absent" "$count" "$(writes)"

echo "== labels-sync touches neither the package label nor its members, before or after the archival"
seed_world
package example-org/shop#5 "$SHOP5"
snapshot() { jq -c --arg n "$NAME" '[.repos["example-org/shop"].labels[] | select(.name == $n)], [.repos["example-org/shop"].issues[] | .labels]' "$GH_REST_STATE/github.json"; }
active="$(snapshot)"
( cd "$WORK/project" && bash "$ROOT/bin/labels-sync.sh" example-org/shop ) > "$WORK/sync.out" 2>&1
check "labels-sync leaves the active package label as it was" "$active" "$(snapshot)"
matches "and reports it as not in labels.tsv, left alone" 'package/shop#5' "$(cat "$WORK/sync.out")"
close_issue example-org/shop 5 completed
package example-org/shop#5 "$SHOP5"
check "the package is archived" true "$(label_archived example-org/shop "$NAME")"
archived="$(snapshot)"
( cd "$WORK/project" && bash "$ROOT/bin/labels-sync.sh" example-org/shop ) > /dev/null 2>&1
check "labels-sync leaves the archived label as it was" "$archived" "$(snapshot)"
check "and makes no label of the name" 0 "$(grep -c '^label create package/' "$GH_REST_STATE/writes.log" || true)"

echo "== a GitHub that does not say whether a label is archived is no archival"
seed_world
package example-org/shop#5 "$SHOP5"
close_issue example-org/shop 5 completed
patch_state '.omit = ["archived_at"]'
package example-org/shop#5 "$SHOP5"
check "the run fails" 1 "$rc"
matches "and says what it could not read" 'did not say whether' "$err"
check "and claims nothing" "" "$out"

echo "== a label made where GitHub's answer does not say whether it is archived: the failure names the label it made"
seed_world
patch_state '.omit = ["archived_at"]'
package example-org/shop#5 "$SHOP5"
check "the run fails" 1 "$rc"
matches "and names the label it made" 'Done before it failed: created package/shop#5 in example-org/shop' "$err"
check "and claims nothing" "" "$out"

echo "== completion and revival"
seed_world
members="$SHOP5 $API7 $LIB4"
package example-org/shop#5 "$members"
close_issue example-org/shop 5 completed
package example-org/shop#5 "$members"
check "the labels stay active while the others are open" fine "$(package_state "$NAME" false $members)"
close_issue example-org/api 7 completed
package example-org/shop#5 "$members"
check "and while one member of another organization is open" fine "$(package_state "$NAME" false $members)"
close_issue other-org/lib 4 completed
package example-org/shop#5 "$members"
check "the last member archives every label" fine "$(package_state "$NAME" true $members)"
matches "and the answer says so" '3 of 3 members complete' "$out"
check "every completed issue is closed and carries its label" "closed closed closed" "$(for m in $members; do jq -r --arg r "${m%#*}" --arg n "${m##*#}" '.repos[$r].issues[$n].state' "$GH_REST_STATE/github.json"; done | paste -sd' ' -)"
count="$(writes)"
package example-org/shop#5 "$members"
check "a run on an archived package writes nothing" "$count" "$(writes)"
reopen_issue example-org/api 7
package example-org/shop#5 "$members"
check "a reopened member makes every label active again" fine "$(package_state "$NAME" false $members)"
check "the label of the reopened member is the same one" 1 "$(label_count example-org/api "$NAME")"
check "and it is complete only once it is closed as completed again" "open" "$(state '.repos["example-org/api"].issues["7"].state')"
close_issue example-org/api 7 completed
package example-org/shop#5 "$members"
check "the new completion archives it again" fine "$(package_state "$NAME" true $members)"

echo "== not planned, no reason and a member that cannot be read keep the label active"
seed_world
package example-org/shop#5 "$SHOP5 $API7"
close_issue example-org/shop 5 completed
close_issue example-org/api 7 not-planned
package example-org/shop#5 "$SHOP5 $API7"
check "a member closed as not planned" fine "$(package_state "$NAME" false "$SHOP5" "$API7")"
seed_world
package example-org/shop#5 "$SHOP5 $API7"
close_issue example-org/shop 5 completed
patch_state '.repos["example-org/api"].issues["7"].state = "closed" | .repos["example-org/api"].issues["7"].state_reason = null'
package example-org/shop#5 "$SHOP5 $API7"
check "a member closed with no reason" fine "$(package_state "$NAME" false "$SHOP5" "$API7")"
seed_world
package example-org/shop#5 "$SHOP5 $API7"
close_issue example-org/shop 5 completed
close_issue example-org/api 7 completed
plant_failure '{"match": "GET repos/example-org/api/issues/7", "times": 20, "status": 500, "message": "Server Error"}'
package example-org/shop#5 "$SHOP5 $API7"
check "a member that cannot be read fails the run" 1 "$rc"
check "and archives nothing" fine "$(package_state "$NAME" false "$SHOP5" "$API7")"

echo "== planted: archival once any member is complete, and a GitHub that ignores the archival"
seed_world
package example-org/shop#5 "$SHOP5 $LIB4"
close_issue example-org/shop 5 completed
package example-org/shop#5 "$SHOP5 $LIB4"
check "innocent: with a member of the other organization open nothing is archived" fine "$(package_state "$NAME" false "$SHOP5" "$LIB4")"
EARLY="$WORK/early"; mkdir -p "$EARLY"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/skills" "$ROOT/VERSION" "$EARLY/"
sed -i.bak 's/\[ ${#members\[@\]} -gt 0 \] \&\& \[ "$complete_count" -eq ${#members\[@\]} \] \&\& complete=true/[ "$complete_count" -ge 1 ] \&\& complete=true/' "$EARLY/bin/issue-package.sh"; rm -f "$EARLY/bin/issue-package.sh.bak"
cmp -s "$ROOT/bin/issue-package.sh" "$EARLY/bin/issue-package.sh" && { echo "  FAIL the plant did not take: archival is not early"; failed=$((failed + 1)); }
ROOT_UNDER_TEST="$EARLY" package example-org/shop#5 "$SHOP5 $LIB4"
matches "the early archival is caught by the oracle" 'archived=true' "$(package_state "$NAME" false "$SHOP5" "$LIB4")"
IGNORES="$WORK/ignores.mjs"
sed 's/label.archived_at = payload.archived ? (label.archived_at ?? .2026-01-01T00:00:00Z.) : null;/label.archived_at = null;/' "$ROOT/tests/gh-rest-fake.mjs" > "$IGNORES"
cmp -s "$ROOT/tests/gh-rest-fake.mjs" "$IGNORES" && { echo "  FAIL the plant did not take: the stand-in still archives"; failed=$((failed + 1)); }
seed_world
package example-org/shop#5 "$SHOP5"
close_issue example-org/shop 5 completed
GH_FAKE_SCRIPT="$IGNORES" package example-org/shop#5 "$SHOP5"
check "a GitHub that keeps nothing of the archival fails the run" 1 "$rc"
matches "and says what it was told instead" 'answered another archival' "$err"
check "and the label is not archived" false "$(label_archived example-org/shop "$NAME")"

echo "== a skill whose command drifted is caught (planted)"
sed 's/ai-core issue-package <first issue/ai-core issue-packages <first issue/' "$SKILL" > "$WORK/stale-skill.md"
seed_world
SKILL_UNDER_TEST="$WORK/stale-skill.md" package example-org/shop#5 "$SHOP5"
check "the extraction fails and no label was made" "99 0" "$rc $(label_count example-org/shop "$NAME")"

echo "== two runs at once"
seed_world
patch_state '.barriers = [{match: "GET repos/example-org/shop/labels", parties: 2}]'
members="$SHOP5 $API7"
command="$(node "$ROOT/tests/package-workflow.mjs" "$SKILL" example-org/shop#5 $(flags "$members" ""))"
( cd "$WORK/project" && bash -c "$command" > "$WORK/out1" 2> "$WORK/err1"; echo $? > "$WORK/rc1" ) &
( cd "$WORK/project" && bash -c "$command" > "$WORK/out2" 2> "$WORK/err2"; echo $? > "$WORK/rc2" ) &
wait
check "both runs of the classification succeed" "0 0" "$(cat "$WORK/rc1") $(cat "$WORK/rc2")"
check "the two runs both tried to make the label of the first repository, and one of them lost" 2 "$(grep -c '^POST repos/example-org/shop/labels$' "$GH_REST_STATE/writes.log")"
check "one label of the name stands in each repository, and the package is whole" fine "$(package_state "$NAME" false "$SHOP5" "$API7")"
check "no unrelated label was lost" "area:tooling type:feature" "$(jq -r '.repos["example-org/shop"].labels | map(select(.name | startswith("package/") | not) | .name) | sort | join(" ")' "$GH_REST_STATE/github.json")"
patch_state '.barriers = []'
members="$SHOP5 $API7 $LIB4"
command="$(node "$ROOT/tests/package-workflow.mjs" "$SKILL" example-org/shop#5 $(flags "$members" ""))"
( cd "$WORK/project" && bash -c "$command" > /dev/null 2>&1 ) &
( cd "$WORK/project" && bash -c "$command" > /dev/null 2>&1 ) &
wait
package example-org/shop#5 "$members"
check "after a member joined, two runs at once leave a whole package" fine "$(package_state "$NAME" false $members)"
close_issue example-org/shop 5 completed; close_issue example-org/api 7 completed; close_issue other-org/lib 4 completed
( cd "$WORK/project" && bash -c "$command" > /dev/null 2>&1 ) &
( cd "$WORK/project" && bash -c "$command" > /dev/null 2>&1 ) &
wait
package example-org/shop#5 "$members"
check "after the completion, two runs at once leave an archived package" fine "$(package_state "$NAME" true $members)"

echo "== a step that fails says what was confirmed, and the next run converges"
seed_world
plant_failure '{"match": "POST repos/example-org/shop/issues/5/labels", "status": 403, "message": "Forbidden"}'
package example-org/shop#5 "$SHOP5 $API7"
check "a refusal on the second repository fails the run" 1 "$rc"
matches "it names what was confirmed" 'Done before it failed: .*labeled example-org/api#7' "$err"
matches "and what failed" 'labeling example-org/shop#5 failed' "$err"
check "it claims nothing on stdout" "" "$out"
package example-org/shop#5 "$SHOP5 $API7"
check "the next run converges" fine "$(package_state "$NAME" false "$SHOP5" "$API7")"
seed_world
plant_failure '{"match": "POST repos/example-org/shop/issues/5/labels", "drop": true}'
package example-org/shop#5 "$SHOP5 $API7"
check "a write whose answer was lost fails the run" 1 "$rc"
matches "and says that it may have happened" 'the write may have happened' "$err"
package example-org/shop#5 "$SHOP5 $API7"
check "the next run reads the tracker and converges" fine "$(package_state "$NAME" false "$SHOP5" "$API7")"
seed_world
plant_failure '{"match": "POST repos/example-org/shop/issues/5/labels", "then": {"removeIssueLabel": ["example-org/shop", 5, "package/shop#5"]}}'
package example-org/shop#5 "$SHOP5 $API7"
check "a read-back that finds another state fails the run" 1 "$rc"
matches "and names the issue" 'example-org/shop#5 carries' "$err"
check "and claims nothing" "" "$out"
package example-org/shop#5 "$SHOP5 $API7"
check "the next run converges" fine "$(package_state "$NAME" false "$SHOP5" "$API7")"
seed_world
members="$SHOP5 $API7 $LIB4"
package example-org/shop#5 "$members"
close_issue example-org/shop 5 completed; close_issue example-org/api 7 completed; close_issue other-org/lib 4 completed
plant_failure '{"match": "PATCH repos/other-org/lib/labels/", "status": 500, "message": "Server Error"}'
package example-org/shop#5 "$members"
check "an archival that fails after two repositories changed fails the run" 1 "$rc"
matches "it names the archival that was done" 'Done before it failed: .*archived package/shop#5 in example-org/api' "$err"
check "and does not claim every label archived" 0 "$(printf '%s%s' "$out" "$err" | grep -c 'every label')"
check "the repositories that were archived stay so, the other stays active" "true true false" "$(label_archived example-org/api "$NAME") $(label_archived example-org/shop "$NAME") $(label_archived other-org/lib "$NAME")"
package example-org/shop#5 "$members"
check "the next run finishes it" fine "$(package_state "$NAME" true $members)"

echo "== the tracker the command serves"
seed_world
( cd "$WORK/project" && TRACKER=plane ai-core issue-package example-org/shop 5 --member "$SHOP5" ) > "$WORK/plane.out" 2>&1
check "a project on another tracker is refused" 1 "$?"
matches "and told why" 'supports GitHub and Forgejo' "$(cat "$WORK/plane.out")"
check "before anything was written" 0 "$(writes)"
matches "the command answers --help with its usage" 'issue-package.sh OWNER/REPO NUMBER --member' "$(ai-core issue-package --help)"

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "all checks passed"
