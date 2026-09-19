# Validate that every rule carries an explicit enforcement tag.
#
#   rules-check.ps1 [-RulesFile <file-or-directory>]
#
[CmdletBinding()]
param (
  [switch]$Help,

  [string]$RulesFile = ""
)

if ($Help -or $args -contains "-h" -or $args -contains "--help" -or $RulesFile -eq "--help" -or $RulesFile -eq "-h") {
  Write-Host "Usage: rules-check.ps1 [-RulesFile <file-or-directory>]"
  Write-Host ""
  Write-Host "Validates that every rule (a bullet with its wrapped lines) ends with an enforcement tag:"
  Write-Host "[machine], [tool], [review] or [discipline]. A directory means every NN-*.md section file in it."
  Write-Host "Default: .ai-core/rules/rules.md in a checkout, or the rules/ directory of the engine."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -RulesFile <path>  File or directory to check"
  Write-Host "  -Help              Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  pwsh -File .ai-core/bin/rules-check.ps1"
  Write-Host "  pwsh -File bin/rules-check.ps1 -RulesFile rules"
  exit 0
}

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($RulesFile)) {
  $RulesFile = if (Test-Path ".ai-core\rules\rules.md") { ".ai-core\rules\rules.md" } elseif (Test-Path "rules" -PathType Container) { "rules" } else { "rules\rules.md" }
}

if (Test-Path $RulesFile -PathType Container) {
  $files = @(Get-ChildItem -Path $RulesFile -File | Where-Object { $_.Name -match "^[0-9][0-9]-.*\.md$" } | Sort-Object Name | ForEach-Object { $_.FullName })
} elseif (Test-Path $RulesFile -PathType Leaf) {
  $files = @($RulesFile)
} else {
  Write-Host "error: rules file or directory not found at $RulesFile" -ForegroundColor Red
  exit 1
}

Write-Host "==> Checking rule enforcement tags in $RulesFile..."

$untagged = 0
$machineCount = 0
$toolCount = 0
$reviewCount = 0
$disciplineCount = 0
$totalRules = 0

# A rule is one bullet with its wrapped continuation lines; the tag stands at its end.
$rule = ""
$currentFile = ""
function Test-Rule {
  if (-not $script:rule) { return }
  $script:totalRules++
  $text = $script:rule
  $short = if ($text.Length -gt 80) { $text.Substring(0, 80) } else { $text }
  $name = Split-Path -Leaf $script:currentFile
  if ($text -match '\[([^\]]+)\]\s*$') {
    $tag = $Matches[1]
    $valid = $false
    if ($tag -match 'machine') { $script:machineCount++; $valid = $true }
    if ($tag -match 'tool') { $script:toolCount++; $valid = $true }
    if ($tag -match 'review') { $script:reviewCount++; $valid = $true }
    if ($tag -match 'discipline') { $script:disciplineCount++; $valid = $true }
    if (-not $valid) {
      Write-Warning "${name}: rule carries unknown tag '$tag': $short"
      $script:untagged++
    }
  } else {
    Write-Host "error: ${name}: rule carries NO enforcement tag: $short" -ForegroundColor Red
    $script:untagged++
  }
  $script:rule = ""
}

foreach ($currentFile in $files) {
  foreach ($line in (Get-Content -Path $currentFile)) {
    if ($line -match '^\s*-\s+') {
      Test-Rule
      $rule = $line
    } elseif ($rule -and $line -match '^\s+\S') {
      $rule = "$rule $line"
    } else {
      Test-Rule
    }
  }
  Test-Rule
}

Write-Host "--------------------------------------------------"
Write-Host "Files checked: $($files.Count)"
Write-Host "Total rules checked: $totalRules"
Write-Host "  [machine]    : $machineCount"
Write-Host "  [tool]       : $toolCount"
Write-Host "  [review]     : $reviewCount"
Write-Host "  [discipline] : $disciplineCount"
Write-Host "--------------------------------------------------"

if ($untagged -gt 0) {
  Write-Host "FAILED: $untagged rule(s) without valid enforcement tags." -ForegroundColor Red
  exit 1
}

Write-Host "✓ All rules carry valid enforcement tags." -ForegroundColor Green
