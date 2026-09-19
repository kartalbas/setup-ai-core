# Validate a solution path and optionally post it under a GitHub issue.
#
#   solution-path.ps1 -File <path> [-Check] [-Issue <number>]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [string]$File = "",
  [switch]$Check,
  [string]$Issue
)

if ($Help -or $args -contains "-h" -or $args -contains "--help" -or $File -eq "--help" -or $File -eq "-h") {
  Write-Host "Usage: solution-path.ps1 -File <path> [-Check]"
  Write-Host ""
  Write-Host "Validates a solution path document against the 8 required sections."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -File <path>  Path to the markdown file"
  Write-Host "  -Check        Enforce validation and exit with error if incomplete"
  Write-Host "  -Help         Show this help message"
  Write-Host ""
  Write-Host "Examples:"
  Write-Host "  pwsh -File .ai-core/bin/solution-path.ps1 -File docs/my-solution.md -Check"
  exit 0
}

if ([string]::IsNullOrWhiteSpace($File)) {
    Write-Error "Missing required parameter: -File <path>"
    exit 1
}

$ErrorActionPreference = 'Stop'

$Required = @(
  'Where a person meets this',
  'What they see today',
  'What the system does behind it',
  'The decision',
  'Options',
  'Recommendation',
  'Code facts',
  'Reuse manifest'
)

if (-not (Test-Path $File)) {
  Write-Error "File not found: $File"
  exit 1
}

$Content = Get-Content $File -Raw
$Missing = @()
$Empty = @()

foreach ($Req in $Required) {
  if ($Content -notmatch "(?i)##\s*$Req") {
    $Missing += $Req
    continue
  }
  
  $Pattern = "(?is)##\s*$Req(.*?)(?=##\s*|$)"
  if ($Content -match $Pattern) {
    $SectionBody = $matches[1]
    $BodyNoComments = $SectionBody -replace '<!--.*?-->', ''
    if ([string]::IsNullOrWhiteSpace($BodyNoComments)) {
      $Empty += $Req
    }
  }
}

Write-Host "==> Validating solution path: $File" -ForegroundColor Cyan

if ($Missing.Count -gt 0) {
  Write-Host "error: missing required sections in $File :" -ForegroundColor Red
  foreach ($M in $Missing) { Write-Host "  - ## $M" -ForegroundColor Red }
}

if ($Empty.Count -gt 0) {
  Write-Host "error: empty sections (or placeholder only) in $File :" -ForegroundColor Red
  foreach ($E in $Empty) { Write-Host "  - ## $E" -ForegroundColor Red }
}

if ($Missing.Count -gt 0 -or $Empty.Count -gt 0) {
  if ($Check) {
    Write-Error "Validation FAILED. All 8 sections must be present and filled with substantive content."
    exit 1
  } else {
    Write-Warning "Validation warnings found. Use -Check to enforce."
  }
} else {
  Write-Host "✓ Solution path is complete and structurally valid." -ForegroundColor Green
}
