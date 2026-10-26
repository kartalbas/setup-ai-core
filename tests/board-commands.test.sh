#!/usr/bin/env bash
# What board-list, board-order, epics-top, board-unarchive, project-new, repo-link and view-filter
# print, and the calls they send, whole and word for word. They go through lib/tracker.sh, so a second tracker
# can answer them; on GitHub the calls are the ones the commands always made. Also schema-check,
# which holds mutations against GitHub's schema and says so, exiting 0, where TRACKER is another.
#
# Run with a FAKE gh on PATH and a board id in the cache, so nothing reaches GitHub. The comparison
# is shown red on a copy of the harness whose provider sends another field, and green on the real one.
#
#   bash tests/board-commands.test.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AI_CORE_HOME="$WORK/ai-core-home" GH_CACHE_DIRECTORY="$WORK/cache" GH_ORG=example-org
mkdir -p "$HOME" "$AI_CORE_HOME" "$WORK/bin" "$WORK/project" "$GH_CACHE_DIRECTORY/7"
git init -q "$WORK/project"
echo PVT_board7 > "$GH_CACHE_DIRECTORY/7/project-id"
printf 'Status\tF1\ttodo\tO1\nStatus\tF1\tdone\tO4\n' > "$GH_CACHE_DIRECTORY/7/fields.tsv"
LOG="$WORK/calls"; export LOG
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s' "$*" | tr -s ' \n' ' ' >> "$LOG"; printf '\n' >> "$LOG"
case "$*" in
  *"fieldValues(first:20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue {"*"state repository"*)
    printf 'todo\tP1\tshop\t4\tFour\t\ndone\tP2\tother-org/lib\t5\tFive\tclosed\n'; exit 0 ;;
  *"nodes { id content"*|*"nodes { id"*"content { ... on Issue { number repository"*"title"*) : ;;
esac
case "$*" in
  *"items(first:100"*"nodes { id content"*) printf '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PVTI_a","content":{"number":3,"title":"EPIC · big","repository":{"nameWithOwner":"example-org/shop"}}},{"id":"PVTI_b","content":{"number":4,"repository":{"nameWithOwner":"example-org/shop"}}}]}}}}'; exit 0 ;;
  *"issue view 3 --repo example-org/shop"*) echo "EPIC · big"; exit 0 ;;
  *"issue view 4 --repo example-org/shop"*) echo "plain"; exit 0 ;;
  *"repos/example-org/shop --jq .node_id"*) echo R_shop; exit 0 ;;
  *linkProjectV2ToRepository*) echo example-org/shop; exit 0 ;;
  *'organization(login:$o){ id }'*) echo O_1; exit 0 ;;
  *'projectV2(number:$n){ id }'*) echo PVT_src; exit 0 ;;
  *copyProjectV2*) printf '12\thttps://example.test/boards/12\n'; exit 0 ;;
  *'views(first:20)'*) printf 'Board\tV_1\nTable\tV_2\n'; exit 0 ;;
  *updateProjectV2View*) echo "Board: repo:example-org/shop"; exit 0 ;;
  *includeArchived*) printf 'PVT_board7\tPVTI_arch\n'; exit 0 ;;
  *unarchiveProjectV2Item*) echo PVTI_arch; exit 0 ;;
esac
echo '{}'
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# run_all <harness root>: each command, what it said, and the calls it sent
run_all() {
  local root="$1"
  : > "$LOG"
  ( cd "$WORK/project" || exit 1
    echo "board-list: $(bash "$root/bin/board-list.sh" --project 7 2>&1 | tr '\n' '|')"
    echo "project-new: $(bash "$root/bin/project-new.sh" 'A board' 5 2>&1 | tr '\n' '|')"
    echo "repo-link: $(bash "$root/bin/repo-link.sh" --project 7 example-org/shop 2>&1 | grep '^linked' | tr '\n' '|')"
    echo "view-filter: $(bash "$root/bin/view-filter.sh" --project 7 --view Board --repo-name shop 2>&1 | tr '\n' '|')"
    echo "board-unarchive: $(bash "$root/bin/board-unarchive.sh" --project 7 example-org/shop 4 2>&1 | tr '\n' '|')"
    echo "board-order: $(echo 'example-org/shop#3' | bash "$root/bin/board-order.sh" --project 7 2>&1 | tr '\n' '|')"
    echo "epics-top: $(bash "$root/bin/epics-top.sh" --project 7 2>&1 | tr '\n' '|')"
  ); grep -E '^(api|issue view|label list)' "$LOG" | sed 's/ *$//' 
}
failed=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected:"; sed 's/^/         /' <<< "$2"; echo "       actual:"; sed 's/^/         /' <<< "$3"; failed=$((failed + 1)); fi
}
expected="$(cat <<'EXPECTED'
board-list: done            P2  other-org/lib          #5    Five  [closed]|todo            P1  shop                   #4    Four|
project-new: created: A board  ->  https://example.test/boards/12|12|
repo-link: linked: example-org/shop|
view-filter: Board: repo:example-org/shop|
board-unarchive: #4 -> back on the board|
board-order: ordered 1 card(s) on board 7, 0 not on it|
epics-top: lifted      example-org/shop#3  EPIC · big|epics: 1 at the top of board 7|
api graphql --paginate -f pid=PVT_board7 -f query= query($pid:ID!, $endCursor:String) { node(id:$pid) { ... on ProjectV2 { items(first:100, after:$endCursor) { pageInfo { hasNextPage endCursor } nodes { fieldValues(first:20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2SingleSelectField { name } } } } } content { ... on Issue { number title state repository { name nameWithOwner } } } } } } } } --jq .data.node.items.nodes[] | select(.content.number != null) | { n: .content.number, t: .content.title, closed: (.content.state == "CLOSED"), r: (.content.repository | if (.nameWithOwner | ascii_downcase) == ("example-org/" + (.name | ascii_downcase)) then .name else .nameWithOwner end), s: ([.fieldValues.nodes[] | select(.field.name == "Status") | .name] | first // "-"), p: ([.fieldValues.nodes[] | select(.field.name == "Priority") | .name] | first // "-") } | "\(.s)\t\(.p)\t\(.r)\t\(.n)\t\(.t)\t\(if .closed then "closed" else "" end)"
api graphql -f o=example-org -f query= query($o:String!){ organization(login:$o){ id } } --jq .data.organization.id
api graphql -f o=example-org -F n=5 -f query= query($o:String!,$n:Int!){ organization(login:$o){ projectV2(number:$n){ id } } } --jq .data.organization.projectV2.id
api graphql -f pid=PVT_src -f oid=O_1 -f t=A board -f query= mutation($pid:ID!,$oid:ID!,$t:String!){ copyProjectV2(input:{projectId:$pid, ownerId:$oid, title:$t, includeDraftIssues:false}){ projectV2 { number url } } } --jq .data.copyProjectV2.projectV2 | "\(.number)\t\(.url)"
api repos/example-org/shop --jq .node_id
api graphql -f pid=PVT_board7 -f rid=R_shop -f query= mutation($pid:ID!, $rid:ID!) { linkProjectV2ToRepository(input:{projectId:$pid, repositoryId:$rid}) { repository { nameWithOwner } } } --jq .data.linkProjectV2ToRepository.repository.nameWithOwner
api --paginate repos/example-org/shop/labels?per_page=100
api graphql -f pid=PVT_board7 -f query= query($pid:ID!){ node(id:$pid){ ... on ProjectV2 { views(first:20){ nodes { id name filter } } } } } --jq .data.node.views.nodes[] | "\(.name)\t\(.id)"
api graphql -f vid=V_1 -f f=repo:example-org/shop -f query= mutation($vid:ID!,$f:String!){ updateProjectV2View(input:{viewId:$vid, filter:$f}){ projectV2View { name filter } } } --jq .data.updateProjectV2View.projectV2View | "\(.name): \(if .filter == "" then "shows everything" else .filter end)"
api graphql -f o=example-org -f n=shop -F num=4 -f query= query($o:String!, $n:String!, $num:Int!) { repository(owner:$o, name:$n) { issue(number:$num) { projectItems(first:20, includeArchived:true) { nodes { id isArchived project { id } } } } } } --jq .data.repository.issue.projectItems.nodes[] | select(.isArchived) | "\(.project.id)\t\(.id)"
api graphql -f pid=PVT_board7 -f iid=PVTI_arch -f query= mutation($pid:ID!, $iid:ID!) { unarchiveProjectV2Item(input:{projectId:$pid, itemId:$iid}) { item { id } } } --jq .data.unarchiveProjectV2Item.item.id
api graphql -f pid=PVT_board7 -f query= query($pid:ID!) { node(id:$pid) { ... on ProjectV2 { items(first:100) { pageInfo { hasNextPage endCursor } nodes { id content { ... on Issue { number repository { nameWithOwner } } } } } } } }
api graphql -f pid=PVT_board7 -f iid=PVTI_a -f query= mutation($pid:ID!, $iid:ID!, $after:ID) { updateProjectV2ItemPosition(input:{ projectId:$pid, itemId:$iid, afterId:$after}) { items { totalCount } } }
api graphql -f pid=PVT_board7 -f query= query($pid:ID!) { node(id:$pid) { ... on ProjectV2 { items(first:100) { pageInfo { hasNextPage endCursor } nodes { id content { ... on Issue { number repository { nameWithOwner } } } } } } } }
issue view 3 --repo example-org/shop --json title --jq .title
issue view 4 --repo example-org/shop --json title --jq .title
api graphql -f pid=PVT_board7 -f iid=PVTI_a -f query= mutation($pid:ID!, $iid:ID!, $after:ID) { updateProjectV2ItemPosition(input:{ projectId:$pid, itemId:$iid, afterId:$after}) { items { totalCount } } }
EXPECTED
)"
actual="$(run_all "$ROOT")"
check "the seven commands say and send what they always did" "$expected" "$actual"

# schema-check on another tracker says so and checks nothing
out="$(cd "$WORK/project" && TRACKER=plane bash "$ROOT/bin/schema-check.sh" 2>&1)"; rc=$?
check "schema-check on another tracker exits 0" "0" "$rc"
check "and prints one line that says so" "schema-check: TRACKER is plane, and the schema it checks against is GitHub's - nothing to check" "$out"

# a part of a call past its 80th character is read: the field item_top adds to its mutation
check "board-order and epics-top send afterId, which stands past the 80th character of the call" "2" "$(grep -c 'afterId:\$after}' <<< "$actual")"

# the planted defect: a provider that sends another field must make the same comparison go red
mkdir -p "$WORK/planted"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$WORK/planted/"
sed -i.bak 's/-f rid="\$rid"/-f repositoryId="$rid"/' "$WORK/planted/lib/github/tracker.sh"
planted="$(run_all "$WORK/planted")"
check "planted: a provider that sends another field is caught" "no" "$([ "$planted" = "$expected" ] && echo yes || echo no)"
check "innocent: the copy still prints what the real one prints" "$(grep -c '^[a-z-]*: ' <<< "$expected")" "$(grep -c '^[a-z-]*: ' <<< "$planted")"
# the planted defect past the 80th character: a provider whose --jq filter differs
mkdir -p "$WORK/planted-jq"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$WORK/planted-jq/"
sed -i.bak 's/\.data\.organization\.id/.data.organization.node/' "$WORK/planted-jq/lib/github/tracker.sh"
planted_jq="$(run_all "$WORK/planted-jq")"
check "planted: a provider that sends another --jq filter is caught" "no" "$([ "$planted_jq" = "$expected" ] && echo yes || echo no)"
check "innocent: the copy with the other filter still prints a line for each command" "$(grep -c '^[a-z-]*: ' <<< "$expected")" "$(grep -c '^[a-z-]*: ' <<< "$planted_jq")"
[ "$failed" -eq 0 ] || { echo "$failed failed"; exit 1; }
