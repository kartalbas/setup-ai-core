# The PowerShell twin of rules-check.test.sh, asserting the SAME reading of the SAME documents.
# Two implementations of one reader are two chances to drift, and a document accepted by one
# shell and refused by the other is the whole reason both are held here.
#
#   pwsh -File test/rules-check.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "rules-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$rules = Join-Path $root 'bin/rules-check.ps1'
function Invoke-Rules($file) {
  $script:out = @(& $rules -File $file 2>&1 | ForEach-Object { "$_" })
  return $LASTEXITCODE
}
function Line($pattern) { return ,@($script:out | Where-Object { $_ -match $pattern }) }

Write-Host 'a document whose every rule carries a tag is green, and the count is per tag'
$good = Join-Path $fake 'good.md'
@'
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
'@ | Set-Content -Path $good -Encoding utf8NoBOM
$rc = Invoke-Rules $good
Check 'exits zero'      0 $rc
Check 'the total'       'rules-check: 5 rule bullets, every one tagged.' $out[-1]
Check 'machine counts twice'              'machine      2' (Line '^machine ')[0]
Check 'tool once'                         'tool         1' (Line '^tool ')[0]
Check 'review counts the combination too' 'review       2' (Line '^review ')[0]
Check 'discipline once'                   'discipline   1' (Line '^discipline ')[0]

# A bullet before the first `## ` heading is a preamble, not a rule. Counting it would make
# the preamble of every document a set of untagged rules.
Write-Host 'a bullet above the first section is not a rule'
Check 'not counted' 0 (Line 'Not a rule').Count

Write-Host 'a bullet with no tag is named with its line, and the run is red'
$bad = Join-Path $fake 'bad.md'
@'
# The rules

## §4 Commits

- **Never stage blindly.** `git add` names its files.
- **A reviewer writes findings and does not push into the tree under review.** [review]
'@ | Set-Content -Path $bad -Encoding utf8NoBOM
$rc = Invoke-Rules $bad
Check 'exits nonzero'  1 $rc
Check 'names the line' 1 (Line ':5 has no enforcement tag: - \*\*Never stage blindly').Count
Check 'the total'      'rules-check: 2 rule bullets, 1 without an enforcement tag.' $out[-1]

Write-Host 'a tag that is not one of the four is no tag at all'
$wrong = Join-Path $fake 'wrong.md'
"# R`n`n## §4`n`n- **A rule.** [enforced]" | Set-Content -Path $wrong -Encoding utf8NoBOM
$rc = Invoke-Rules $wrong
Check 'exits nonzero'  1 $rc
Check 'names the line' 1 (Line ':5 has no enforcement tag').Count

Write-Host 'a combination naming the same tag twice is no tag either'
$twice = Join-Path $fake 'twice.md'
"# R`n`n## §4`n`n- **A rule.** [review · review]" | Set-Content -Path $twice -Encoding utf8NoBOM
$rc = Invoke-Rules $twice
Check 'exits nonzero' 1 $rc

Write-Host 'a bullet that is not a rule bullet is not counted'
$plain = Join-Path $fake 'plain.md'
@'
# R

## §4

- A plain list item, with no bold opening.
- **A rule.** [tool]
'@ | Set-Content -Path $plain -Encoding utf8NoBOM
$rc = Invoke-Rules $plain
Check 'exits zero' 0 $rc
Check 'one bullet' 'rules-check: 1 rule bullets, every one tagged.' $out[-1]

# A rule regularly runs over several lines, and the tag stands at the end of the LAST of them.
# Reading only the first line would refuse every rule long enough to need one.
Write-Host 'a bullet whose tag stands on a later line is read whole'
$wrapped = Join-Path $fake 'wrapped.md'
@'
# R

## §8

- **No issue without a person's yes.** The ask carries the whole case: where it comes from,
  what a person meets today with evidence, why a ticket and not a sentence, whose repository
  it is and why, what done looks like, what waiting costs, and the ticket as it would be
  filed. [tool]

- **The title carries an action and its stake.** [review]
'@ | Set-Content -Path $wrapped -Encoding utf8NoBOM
$rc = Invoke-Rules $wrapped
Check 'exits zero'  0 $rc
Check 'two bullets' 'rules-check: 2 rule bullets, every one tagged.' $out[-1]

# A SET OF RULES THAT HAS AN ORDER IS WRITTEN AS A NUMBERED LIST, and a rule that opens a
# section is written as a paragraph of its own at the left margin. Read only as `- **` bullets,
# neither is counted and neither could lose its tag without the count staying the same.
Write-Host 'a numbered rule and a rule written as a paragraph are rules too'
$shapes = Join-Path $fake 'shapes.md'
@'
# R

## §12 Model choice

**The top tier never writes code and never runs a main session.** It decides, reviews and
briefs, because it is the slowest tier and the one that falls back without saying so. [discipline]

1. **Pass an explicit model and an explicit effort on every agent call.** [discipline]
2. **Effort is never below the second-highest setting a tool offers**, and the architect, the
   implementer and the reviewer run on the highest. [machine · review]
3. A plain numbered item, with no bold opening.
'@ | Set-Content -Path $shapes -Encoding utf8NoBOM
$rc = Invoke-Rules $shapes
Check 'exits zero' 0 $rc
Check 'three rules, and the plain item is not one' 'rules-check: 3 rule bullets, every one tagged.' $out[-1]
Check 'the paragraph and the first numbered rule'  'discipline   2' (Line '^discipline ')[0]
Check 'the numbered combination, machine side'     'machine      1' (Line '^machine ')[0]
Check 'the numbered combination, review side'      'review       1' (Line '^review ')[0]

Write-Host 'a numbered rule and a paragraph rule with no tag are named and refused'
$shapeless = Join-Path $fake 'shapeless.md'
@'
# R

## §12 Model choice

**The top tier never writes code and never runs a main session.**

1. **Pass an explicit model and an explicit effort on every agent call.**
'@ | Set-Content -Path $shapeless -Encoding utf8NoBOM
$rc = Invoke-Rules $shapeless
Check 'exits nonzero'          1 $rc
Check 'the paragraph is named' 1 (Line ':5 has no enforcement tag: \*\*The top tier').Count
Check 'the numbered rule too'  1 (Line ':7 has no enforcement tag: 1\. \*\*Pass an explicit model').Count
Check 'the total'              'rules-check: 2 rule bullets, 2 without an enforcement tag.' $out[-1]

Write-Host 'a file that is not there is refused'
$rc = Invoke-Rules (Join-Path $fake 'nope.md')
Check 'exits nonzero'     2 $rc
Check 'the file is named' 1 (Line 'there is no file at').Count

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
