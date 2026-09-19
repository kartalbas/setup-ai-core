[CmdletBinding()]
param ([switch]$Help)

if ($Help -or $args -contains "-h" -or $args -contains "--help") {
  Write-Host "Usage: install-skills.ps1"
  Write-Host "Links AI agent community skills from the rules/skills.md definition."
  exit 0
}
Write-Host "==> Community skills (mattpocock, caveman, ponytail) are defined in .ai-core/rules/skills.md."
Write-Host "==> No npm package installation required."
exit 0
