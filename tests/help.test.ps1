# The PowerShell twin of help.test.sh: every command answers --help through ai-core.ps1 with
# exit 0, some text and no error. It walks every script in bin\, in a temporary folder that is no
# repository, with HOME pointed into it.
#
#   pwsh -File tests/help.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) "help-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Force -Path (Join-Path $work 'home') | Out-Null
$keptHome = $env:HOME; $keptProfile = $env:USERPROFILE
$env:HOME = Join-Path $work 'home'; $env:USERPROFILE = $env:HOME; $env:AI_CORE_HOME = $env:HOME

$failed = 0; $walked = 0
Push-Location $work
try {
  foreach ($f in (Get-ChildItem -Path (Join-Path $root 'bin') -Filter '*.ps1' | Sort-Object Name)) {
    if ($f.BaseName -ceq 'ai-core') { continue }
    $walked++
    $out = (& pwsh -NoProfile -File (Join-Path $root 'bin/ai-core.ps1') $f.BaseName --help 2>&1 | Out-String)
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -or -not $out.Trim() -or $out -imatch 'unknown argument|(?m)^error|cannot be found') {
      Write-Host "  FAIL $($f.BaseName) --help: exit ${rc}: $((($out -split "`n") | Select-Object -First 2) -join ' ')"
      $failed++
    }
  }
} finally {
  Pop-Location
  $env:HOME = $keptHome; $env:USERPROFILE = $keptProfile; $env:AI_CORE_HOME = $null
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host "  $walked commands walked"
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
