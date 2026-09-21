#!/usr/bin/env bash
# Which lines rules-check.sh reads as a rule, and which tags it accepts.
#
# Nothing reaches github.com: the file is the whole input. What is pinned: a rule bullet is a
# line starting with `- **` under a `## ` section, a bullet that runs over several lines is read
# to its end, a combination of two tags is one tag on each side of the count, and a bullet with
# no tag is named with its line number and turns the run red.
#
#   bash test/rules-check.test.sh

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT

failed=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok   $1"
  else echo "  FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"; failed=$((failed + 1)); fi
}

rules="$root/bin/rules-check.sh"

echo 'a document whose every rule carries a tag is green, and the count is per tag'
good="$fake/good.md"
cat > "$good" <<'TEXT'
# The rules

A bullet up here is not a rule: it stands before the first section.

- **Not a rule** because nothing has opened a section yet.

## §4 Commits

- **Never stage blindly.** `git add` names its files. [machine]
- **Every commit names the issues it touches**, or is a release stamp, or explains only, or
  carries a `No-issue:` trailer naming who asked. The hook reads the whole message, so the
  number may stand anywhere in it. [machine · review]
- **A reviewer writes findings and does not push into the tree under review.** [review]

## §7 Language

- **Simplified technical English on disk.** [discipline]
- **Every issue names who asked for it.** [tool]
TEXT
out="$("$rules" "$good" 2>&1)"; rc=$?
check 'exits zero'       0 "$rc"
check 'the total'        'rules-check: 5 rule bullets, every one tagged.' "$(printf '%s\n' "$out" | tail -1)"
check 'machine counts twice'  'machine      2' "$(printf '%s\n' "$out" | grep '^machine ')"
check 'tool once'             'tool         1' "$(printf '%s\n' "$out" | grep '^tool ')"
check 'review counts the combination too' 'review       2' "$(printf '%s\n' "$out" | grep '^review ')"
check 'discipline once'       'discipline   1' "$(printf '%s\n' "$out" | grep '^discipline ')"

# A bullet before the first `## ` heading is a preamble, not a rule. Counting it would make
# the preamble of every document a set of untagged rules.
echo 'a bullet above the first section is not a rule'
check 'not counted' no "$(printf '%s\n' "$out" | grep -q 'Not a rule' && echo yes || echo no)"

echo 'a bullet with no tag is named with its line, and the run is red'
bad="$fake/bad.md"
cat > "$bad" <<'TEXT'
# The rules

## §4 Commits

- **Never stage blindly.** `git add` names its files.
- **A reviewer writes findings and does not push into the tree under review.** [review]
TEXT
out="$("$rules" "$bad" 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the line' yes "$(printf '%s\n' "$out" | grep -q "^$bad:5 has no enforcement tag: - \*\*Never stage blindly" && echo yes || echo no)"
check 'the total'      'rules-check: 2 rule bullets, 1 without an enforcement tag.' "$(printf '%s\n' "$out" | tail -1)"

echo 'a tag that is not one of the four is no tag at all'
wrong="$fake/wrong.md"
printf '# R\n\n## §4\n\n- **A rule.** [enforced]\n' > "$wrong"
out="$("$rules" "$wrong" 2>&1)"; rc=$?
check 'exits nonzero'  yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'names the line' yes "$(printf '%s\n' "$out" | grep -q ":5 has no enforcement tag" && echo yes || echo no)"

echo 'a combination naming the same tag twice is no tag either'
twice="$fake/twice.md"
printf '# R\n\n## §4\n\n- **A rule.** [review · review]\n' > "$twice"
out="$("$rules" "$twice" 2>&1)"; rc=$?
check 'exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"

echo 'a bullet that is not a rule bullet is not counted'
plain="$fake/plain.md"
cat > "$plain" <<'TEXT'
# R

## §4

- A plain list item, with no bold opening.
- **A rule.** [tool]
TEXT
out="$("$rules" "$plain" 2>&1)"; rc=$?
check 'exits zero'  0 "$rc"
check 'one bullet'  'rules-check: 1 rule bullets, every one tagged.' "$(printf '%s\n' "$out" | tail -1)"

# A rule regularly runs over several lines, and the tag stands at the end of the LAST of them.
# Reading only the first line would refuse every rule long enough to need one.
echo 'a bullet whose tag stands on a later line is read whole'
wrapped="$fake/wrapped.md"
cat > "$wrapped" <<'TEXT'
# R

## §8

- **No issue without a person's yes.** The ask carries the whole case: where it comes from,
  what a person meets today with evidence, why a ticket and not a sentence, whose repository
  it is and why, what done looks like, what waiting costs, and the ticket as it would be
  filed. [tool]

- **The title carries an action and its stake.** [review]
TEXT
out="$("$rules" "$wrapped" 2>&1)"; rc=$?
check 'exits zero'  0 "$rc"
check 'two bullets' 'rules-check: 2 rule bullets, every one tagged.' "$(printf '%s\n' "$out" | tail -1)"

# A SET OF RULES THAT HAS AN ORDER IS WRITTEN AS A NUMBERED LIST, and a rule that opens a
# section is written as a paragraph of its own at the left margin. Read only as `- **` bullets,
# neither is counted and neither could lose its tag without the count staying the same.
echo 'a numbered rule and a rule written as a paragraph are rules too'
shapes="$fake/shapes.md"
cat > "$shapes" <<'TEXT'
# R

## §12 Model choice

**The top tier never writes code and never runs a main session.** It decides, reviews and
briefs, because it is the slowest tier and the one that falls back without saying so. [discipline]

1. **Pass an explicit model and an explicit effort on every agent call.** [discipline]
2. **Effort is never below the second-highest setting a tool offers**, and the architect, the
   implementer and the reviewer run on the highest. [machine · review]
3. A plain numbered item, with no bold opening.
TEXT
out="$("$rules" "$shapes" 2>&1)"; rc=$?
check 'exits zero' 0 "$rc"
check 'three rules, and the plain item is not one' \
  'rules-check: 3 rule bullets, every one tagged.' "$(printf '%s\n' "$out" | tail -1)"
check 'the paragraph and the first numbered rule'  'discipline   2' "$(printf '%s\n' "$out" | grep '^discipline ')"
check 'the numbered combination, machine side'     'machine      1' "$(printf '%s\n' "$out" | grep '^machine ')"
check 'the numbered combination, review side'      'review       1' "$(printf '%s\n' "$out" | grep '^review ')"

echo 'a numbered rule and a paragraph rule with no tag are named and refused'
shapeless="$fake/shapeless.md"
cat > "$shapeless" <<'TEXT'
# R

## §12 Model choice

**The top tier never writes code and never runs a main session.**

1. **Pass an explicit model and an explicit effort on every agent call.**
TEXT
out="$("$rules" "$shapeless" 2>&1)"; rc=$?
check 'exits nonzero'          yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'the paragraph is named' yes "$(printf '%s\n' "$out" | grep -q "^$shapeless:5 has no enforcement tag: \*\*The top tier" && echo yes || echo no)"
check 'the numbered rule too'  yes "$(printf '%s\n' "$out" | grep -q "^$shapeless:7 has no enforcement tag: 1\. \*\*Pass an explicit model" && echo yes || echo no)"
check 'the total'              'rules-check: 2 rule bullets, 2 without an enforcement tag.' "$(printf '%s\n' "$out" | tail -1)"

echo 'a file that is not there is refused, and a missing argument too'
out="$("$rules" "$fake/nope.md" 2>&1)"; rc=$?
check 'exits nonzero'     yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
check 'the file is named' yes "$(printf '%s\n' "$out" | grep -q "there is no file at $fake/nope.md" && echo yes || echo no)"
# Without an argument the default is the checkout's rules or the clone's rules/; where neither exists, it refuses
out="$(cd "$fake" && "$rules" 2>&1)"; rc=$?
check 'no argument and no default here: exits nonzero' yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"

if [ "$failed" -gt 0 ]; then echo; echo "$failed failed"; exit 1; fi
echo
echo 'all passed'
