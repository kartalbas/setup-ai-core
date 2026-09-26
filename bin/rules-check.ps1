# Does every rule carry the mechanism that enforces it?
#
#   rules-check.ps1 [-RulesFile <file-or-directory>]
#
# A rule is a bold opening under a `## ` section, written in one of three shapes:
#   - **A rule.**      a list bullet
#   3. **A rule.**     a numbered item, which is how a set of rules that has an order is written
#   **A rule.**        a paragraph of its own, at the left margin
# Every one of them ends with an enforcement tag naming what actually holds it:
#   [machine]     a lint, a test or a hook refuses
#   [tool]        a command does it at the moment of the action
#   [review]      the reviewer's checklist asks for it
#   [discipline]  only the reader
# Two mechanisms sharing one rule are written as a combination, `[machine · review]`, joined with
# a middle dot. The order does not matter and a tag may not stand twice in one combination.
#
# A RULE IS ITS WHOLE PARAGRAPH: a list bullet is its opening line plus the indented lines under
# it, a paragraph its opening line plus the lines at the left margin under it, up to the blank
# line. The tag is looked for at the end of the last of them.
#
# It prints one line per untagged rule, naming the file and the line, then the count per tag over
# every file read. Exits 1 when any rule has no tag. A directory means its NN-*.md section files;
# without an argument it reads .ai-core\rules\rules.md in a checkout, or rules\ in the clone.
[CmdletBinding()]
param (
  [switch]$Help,
  [Parameter(Position = 0)][Alias('File')][string]$RulesFile = ""
)

if ($Help -or $RulesFile -ceq "-h" -or $RulesFile -ceq "--help" -or $args -ccontains "-h" -or $args -ccontains "--help") {
  Write-Host "Usage: rules-check.ps1 [-RulesFile <file-or-directory>]"
  Write-Host ""
  Write-Host "Refuses a rule (a bold opening under a ## section, with the lines it wraps over) that does not"
  Write-Host "end with an enforcement tag: [machine], [tool], [review], [discipline], or a combination such"
  Write-Host "as [machine · review]. Prints every untagged rule with its file and line, then the count per tag."
  Write-Host "A directory means every NN-*.md section file in it."
  Write-Host "Default: .ai-core\rules\rules.md in a checkout, or the rules\ directory of setup-ai-core."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -RulesFile <path>   The rules file or the directory of section files"
  Write-Host "  -Help               Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  ai-core rules-check"
  Write-Host "  ai-core rules-check rules"
  exit 0
}
if ($args.Count -gt 0) { Write-Host "error: unknown argument '$($args[0])'"; exit 2 }

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$target = $RulesFile
if (-not $target) {
  if (Test-Path ".ai-core\rules\rules.md") { $target = ".ai-core\rules\rules.md" }
  elseif (Test-Path "rules" -PathType Container) { $target = "rules" }
  else { $target = "rules\rules.md" }
}
# A PROJECT HARNESS - a directory with rules\, skills\ or agents\ - is checked whole. Every skill and
# agent it lays into the checkouts has the front matter the agent tools read: a name (a skill's is
# the name of its folder) and a description; an agent names no model below Sonnet. Then its rules\
# is read as a directory of sections, when it has any.
$harnessBad = 0; $harnessSeen = ''
if ((Test-Path -LiteralPath $target -PathType Container) -and (@('rules', 'skills', 'agents') | Where-Object { Test-Path -LiteralPath (Join-Path $target $_) -PathType Container })) {
  function Get-Front([string]$file, [string]$key) {  # the value of <key> in the front matter, quotes taken off; $null without front matter
    $lines = @([System.IO.File]::ReadAllLines($file))
    if ($lines.Count -eq 0 -or $lines[0].TrimEnd() -cne '---') { return $null }
    for ($i = 1; $i -lt $lines.Count; $i++) {
      $l = $lines[$i].TrimEnd("`r")
      if ($l.StartsWith('---', [StringComparison]::Ordinal)) { break }
      if ($l.StartsWith("${key}:", [StringComparison]::Ordinal)) { return $l.Substring($key.Length + 1).Trim().Trim('"', "'") }
    }
    return ''
  }
  $skills = 0; $agents = 0
  foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $target 'skills') -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $f = Join-Path $dir.FullName 'SKILL.md'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
    $skills++
    if ($null -eq (Get-Front $f 'name')) { "${f}: no front matter"; $harnessBad++; continue }
    if ((Get-Front $f 'name') -cne $dir.Name) { "${f}: its name is '$(Get-Front $f 'name')', not its folder's '$($dir.Name)'"; $harnessBad++ }
    if (-not (Get-Front $f 'description')) { "${f}: no description"; $harnessBad++ }
  }
  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $target 'agents') -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -cne 'README.md' } | Sort-Object Name)) {
    $f = $file.FullName
    $agents++
    if ($null -eq (Get-Front $f 'name')) { "${f}: no front matter"; $harnessBad++; continue }
    if (-not (Get-Front $f 'name')) { "${f}: no name"; $harnessBad++ }
    if (-not (Get-Front $f 'description')) { "${f}: no description"; $harnessBad++ }
    if ("$(Get-Front $f 'model')".ToLowerInvariant().Contains('haiku')) { "${f}: model '$(Get-Front $f 'model')' is below Sonnet"; $harnessBad++ }
  }
  $harnessSeen = "$skills skill(s) and $agents agent(s), $harnessBad with a problem"
  $rulesDir = Join-Path $target 'rules'
  if (@(Get-ChildItem -LiteralPath $rulesDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch '^[0-9][0-9]-.*\.md$' }).Count -gt 0) {
    $target = $rulesDir
  } else {
    "rules-check: $harnessSeen; no rule section of its own."
    if ($harnessBad -gt 0) { exit 1 } else { exit 0 }
  }
}
if (Test-Path -LiteralPath $target -PathType Container) {
  $files = @(Get-ChildItem -LiteralPath $target -File | Where-Object { $_.Name -cmatch '^[0-9][0-9]-.*\.md$' } | Sort-Object Name | ForEach-Object { $_.FullName })
  if ($files.Count -eq 0) { "error: no NN-*.md section file in $target"; exit 2 }
} elseif (Test-Path -LiteralPath $target -PathType Leaf) {
  $files = @($target)
} else {
  "error: there is no file at $target"; exit 2
}

$Tags = @('machine', 'tool', 'review', 'discipline')

# The rules of one file: line number and the whole rule, its wrapped lines joined
function Close-Bullet {
  if ($script:open) { $script:bullets.Add([pscustomobject]@{ At = $script:at; Text = $script:text.TrimEnd() }) }
  $script:open = $false; $script:para = $false; $script:text = ''
}
function Get-Rules([string]$file) {
  $script:bullets = [System.Collections.Generic.List[object]]::new()
  $script:open = $false; $script:para = $false; $script:at = 0; $script:text = ''
  $section = $false
  $lines = [IO.File]::ReadAllLines($file)
  for ($i = 0; $i -lt $lines.Length; $i++) {
    $line = $lines[$i]
    if ($line -match '^##[ \t]')            { Close-Bullet; $section = $true; continue }
    if (-not $section)                      { continue }
    if ($line -match '^-[ \t]+\*\*')        { Close-Bullet; $script:open = $true; $script:at = $i + 1; $script:text = $line; continue }
    if ($line -match '^[0-9]+\.[ \t]+\*\*') { Close-Bullet; $script:open = $true; $script:at = $i + 1; $script:text = $line; continue }
    if ($line -match '^\*\*')               { Close-Bullet; $script:open = $true; $script:para = $true; $script:at = $i + 1; $script:text = $line; continue }
    if ($line -match '^[ \t]*\z')           { Close-Bullet; continue }
    if ($line -match '^[-*+][ \t]')         { Close-Bullet; continue }
    if ($line -match '^[0-9]+\.[ \t]')      { Close-Bullet; continue }
    if ($script:open -and $line -match '^[ \t]+\S') { $script:text = $script:text + ' ' + $line.TrimStart(); continue }
    if ($script:para)                       { $script:text = $script:text + ' ' + $line; continue }
    Close-Bullet
  }
  Close-Bullet
  return $script:bullets
}

# The tags named inside the brackets, or nothing when the text is no tag: a word outside the
# four, a word standing twice, or a bracket inside the brackets
function Read-Tag([string]$Inside) {
  if ($Inside -match '[\[\]]') { return @() }
  $named = @()
  foreach ($part in ($Inside -split ' · ')) {
    if ($Tags -cnotcontains $part) { return @() }
    if ($named -ccontains $part)  { return @() }
    $named += $part
  }
  return $named
}

$total = 0
$untagged = 0
$counts = @{}
foreach ($tag in $Tags) { $counts[$tag] = 0 }
foreach ($file in $files) {
  foreach ($bullet in (Get-Rules $file)) {
    $total++
    $named = @()
    if ($bullet.Text -match '\[([^\[\]]*)\]\z') { $named = Read-Tag $Matches[1] }
    if ($named.Count -eq 0) {
      $untagged++
      $short = if ($bullet.Text.Length -gt 72) { $bullet.Text.Substring(0, 72) } else { $bullet.Text }
      "$($file):$($bullet.At) has no enforcement tag: $short"
      continue
    }
    foreach ($tag in $named) { $counts[$tag]++ }
  }
}
''
foreach ($tag in $Tags) { '{0,-12} {1}' -f $tag, $counts[$tag] }
''
if ($untagged -gt 0) {
  "rules-check: $total rule bullets, $untagged without an enforcement tag."
  if ($harnessSeen) { "rules-check: $harnessSeen." }
  exit 1
}
"rules-check: $total rule bullets, every one tagged."
if ($harnessSeen) { "rules-check: $harnessSeen." }
if ($harnessBad -gt 0) { exit 1 } else { exit 0 }
