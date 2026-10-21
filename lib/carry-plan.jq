# The plan of an issue carry, from what GitHub holds to what Plane is to be given. Run by lib/carry.sh as
#   jq -n -f lib/carry-plan.jq --slurpfile source <rows> --argjson destinations <repo -> destination> --arg now <ISO time>
# `source` holds the rows of github_carry_repositories, github_carry_issues and github_carry_boards;
# `destinations` maps each repository that has a destination to its destination key. The answer is
#   {rows: [work item to create, parents before sub-issues, boards last], report: {every count the run prints first}}
# Nothing is written here and nothing is guessed: a value Plane has no field for goes into the text of the
# provenance comment, and the issue body is the source body to the byte.

def lc: ascii_downcase;
def address: test("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}");
def terminal: (. // "" | lc) == "done";
def nonempty: select(. != null and . != "");
def priority_name: {P0: "urgent", P1: "high", P2: "medium", P3: "low"};
def names($xs): $xs | map(. // "none") | join(", ");

($source | map(select(.kind == "repository"))) as $repositories
| ($source | map(select(.kind == "issue"))) as $issues
| ($source | map(select(.kind == "board"))) as $boards
| ($issues | map({key: "\(.repo)#\(.number)", value: .}) | from_entries) as $by
| ($boards | map({key: .id, value: .}) | from_entries) as $board_by
| ($destinations | to_entries | map(.value) | unique) as $all_destinations

| def depth: if .parent == null then 0 else ($by["\(.parent.repo)#\(.parent.number)"]) as $p | if $p == null then 0 else 1 + ($p | depth) end end;

def lifecycle:
  . as $i
  | ($i.memberships | map(select(.archived | not))) as $active
  | ($active | map(.status // "") | unique_by(lc)) as $statuses
  | (if ($i.memberships | length) > 0 and ($i.memberships | all(.archived)) then true else false end) as $all_archived
  | if $i.state == "OPEN" then
      if ($statuses | length) == 1 and ($statuses[0] != "") and ($statuses[0] | terminal | not)
      then {mode: "status", name: $statuses[0], archived: false, why: "the one active Status"}
      else {mode: "default", archived: false,
            why: (if ($active | length) == 0 then "no active card"
                  elif ($statuses | length) == 1 then "only the terminal or empty Status \($statuses[0])"
                  else "differing active Status values (\($statuses | join(", ")))" end)}
      end
    elif ($i.reason == "NOT_PLANNED" or $i.reason == "DUPLICATE")
    then {mode: "cancelled", archived: $all_archived, why: "closed as \($i.reason)"}
    else {mode: "done", archived: $all_archived, why: "closed as \($i.reason // "COMPLETED")"} end;

def native_priority:
  . as $i
  | ($i.memberships | map(select(.archived | not))) as $active
  | (if ($active | length) > 0 then $active else $i.memberships end | map(.priority // "") | unique) as $values
  | if ($values | length) == 1 then (priority_name[$values[0]] // "none") else "none" end;

def comment_text($i; $n; $total):
  "Comment \($n) of \($total) by \(if .author == null then "an unavailable author" else "@" + .author end) on \(.createdAt)\n\(.url)\n\n\(.body)";

def provenance($i; $life; $parent; $destination):
  ($i.memberships) as $m
  | "Carried from GitHub \($i.repo)#\($i.number) (\($i.url)); source issue \($i.id); GitHub read at \($now).\n"
    + "Source state: \($i.state), close reason: \($i.reason // "none")."
    + (if $i.reason == "NOT_PLANNED" and ($i.comments | any(.body | test("^Moved to https?://[^ ]*/browse/[A-Za-z0-9_]+-[0-9]+/?\\s*$")))
       then " The issue carries a \"Moved to\" comment, so this close may be the close of an earlier carry; its cause is not established." else "" end)
    + "\nLifecycle: \($life.mode) (\($life.why))" + (if $life.archived then ", archived on the date of this carry" else "" end) + ".\n"
    + "Board memberships (\($m | length)): "
    + (if ($m | length) == 0 then "none" else ($m | map("board \($board_by[.board].number // .board) \"\($board_by[.board].title // "")\" item \(.item): Status \(.status // "none"), Priority \(.priority // "none"), \(if .archived then "archived" else "active" end)") | join("; ")) end) + ".\n"
    + (if ($m | any(.priority == "P9")) then "Priority P9 (parked) is carried as the label P9; Plane has no such priority and the native priority is \($i | native_priority).\n" else "" end)
    + (if $parent == null then "" else "Parent: \($parent.repo)#\($parent.number) (\($parent.url)), " + ($parent.how) + ".\n" end)
    + "Destination: \($destination).";

def issue_row:
  . as $i
  | ($i | lifecycle) as $life
  | ($destinations[$i.repo]) as $dest
  | (if $i.parent == null then null
     else ($i.parent + {ref: "\($i.parent.repo)#\($i.parent.number)"}) as $p
       | $p + (if $by[$p.ref] == null then {mode: "outside", how: "outside the selected issues; it is used when it is carried into this destination already"}
               elif $destinations[$p.repo] == $dest then {mode: "selected", how: "a sub-issue in Plane"}
               else {mode: "reference", how: "in another destination, so it is a recorded relationship and not a Plane sub-issue"} end) end) as $parent
  | {kind: "issue", ref: "\($i.repo)#\($i.number)", dest: $dest, repo: $i.repo, title: $i.title, body: $i.body,
     labels: ([$i.labels[], "repo:\($i.repo | split("/")[1])"] + (if ($i.memberships | any(.priority == "P9")) then ["P9"] else [] end) | unique),
     priority: ($i | native_priority), state: ($life | {mode, name, group: .mode}), archived: $life.archived, parent: $parent,
     comments: (($i.comments | length) as $total | [$i.comments | to_entries[] | .key as $k | .value | {external_id: .id, created_at: .createdAt, text: comment_text($i; $k + 1; $total)}]),
     provenance: {external_id: $i.id, created_at: $now, text: provenance($i; $life; $parent; $dest)}};

def board_destinations:
  . as $b
  | ([$b.items[] | select(.repo != null) | $destinations[.repo] | select(. != null)]
     + [$b.repositories[] | select(.archived | not) | $destinations[.repo] | select(. != null)]) | unique
  | if length > 0 then . else $all_destinations end;

def board_text:
  . as $b
  | "Board \($b.number) \"\($b.title)\" of GitHub, \($b.url); source id \($b.id); GitHub read at \($now).\n"
    + "State: \(if $b.closed then "closed" else "open" end) on GitHub. This work item is a stored snapshot: its own state (completed, archived) says nothing about the board.\n"
    + "Readme: \($b.readme)\n"
    + "Linked repositories: \($b.repositories | map("\(.repo)\(if .archived then " (archived)" else "" end)") | join(", "))\n"
    + "Cards (\($b.items | length)):\n"
    + ($b.items | map("- item \(.item): \(if .issue == null then "no issue" else "\(.repo)#\(.number) issue \(.issue)" end), Status \(.status // "none"), Priority \(.priority // "none"), \(if .archived then "archived" else "active" end)") | join("\n"));

($issues | map(select($destinations[.repo] != null)) | sort_by(depth)) as $selected
| ($selected | map(issue_row)) as $issue_rows
| ($boards | map(. as $b | ($b | board_destinations)[] as $d
      | {kind: "board", ref: $b.id, dest: $d, repo: null, title: $b.title, body: ($b | board_text), labels: [], priority: "none",
         state: {mode: "done", group: "done"}, archived: true, parent: null, comments: [], provenance: null})) as $board_rows

| ($selected | map(.comments | length) | add // 0) as $original_comments
| ($selected | map(select(.parent != null))) as $with_parent
| ($issue_rows | map(select(.parent != null))) as $parents
| ($selected | map(.memberships | map(select(.archived)) | length) | add // 0) as $archived_memberships
| {rows: ($issue_rows + $board_rows),
   report: {
     repositories_selected: ($destinations | length),
     repositories_skipped: [$repositories[] | select(.archived) | .repo],
     issues: ($selected | length),
     issues_without_destination: [$issues[] | select($destinations[.repo] == null) | "\(.repo)#\(.number)"],
     issues_open: ($issue_rows | map(select(.state.mode == "status" or .state.mode == "default")) | length),
     issues_done: ($issue_rows | map(select(.state.mode == "done")) | length),
     issues_cancelled: ($issue_rows | map(select(.state.mode == "cancelled")) | length),
     comments_original: $original_comments,
     comments_provenance: ($selected | length),
     comment_pages: ($selected | map(((.comments | length) + 1 + 99) / 100 | floor) | add // 0),
     archived_memberships: $archived_memberships,
     archived_issues: ($selected | map(select(.memberships | any(.archived))) | length),
     memberships: ($selected | map(.memberships | length) | add // 0),
     boardless_issues: ($selected | map(select(.memberships | length == 0)) | length),
     parent_links: ($parents | length),
     parents_native: ($parents | map(select(.parent.mode == "selected")) | length),
     parents_reference: ($parents | map(select(.parent.mode == "reference")) | length),
     parents_outside: ($parents | map(select(.parent.mode == "outside")) | length),
     parents_outside_distinct: ($parents | map(select(.parent.mode == "outside") | .parent.ref) | unique | length),
     boards_source: ($boards | length),
     board_records: ($board_rows | length),
     boards_empty: ($boards | map(select(.items | length == 0)) | length),
     boards_closed: ($boards | map(select(.closed)) | length),
     boards_spanning: ($boards | map(select((board_destinations | length) > 1)) | length),
     board_memberships_total: ($boards | map(.items | length) | add // 0),
     p9_issues: ($selected | map(select(.memberships | any(.priority == "P9"))) | length),
     address_issues: ($selected | map(select(([.title, .body] + (.comments | map(.body))) | any(address))) | length),
     address_titles: ($selected | map(select(.title | address)) | length),
     address_bodies: ($selected | map(select(.body | address)) | length),
     address_comments: ($selected | map(.comments | map(select(.body | address)) | length) | add // 0),
     conflicting_status_issues: ($selected | map(select(.state != "CLOSED" and ((.memberships | map(select(.archived | not) | .status // "") | unique_by(lc)) | length) > 1)) | length),
     destinations: ($issue_rows + $board_rows | map(.dest) | unique),
     issues_by_destination: ($issue_rows | group_by(.dest) | map({key: .[0].dest, value: length}) | from_entries)
   }}
