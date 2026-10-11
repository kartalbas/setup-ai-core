# The PowerShell twin of contract-scan.test.sh, asserting the SAME lines and the SAME exit codes
# on the same project folder.
#
#   pwsh -File tests/contract-scan.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$t = Join-Path ([IO.Path]::GetTempPath()) "contract-scan-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$env:GIT_CONFIG_GLOBAL = if ($IsWindows) { 'NUL' } else { '/dev/null' }
$env:GIT_CONFIG_NOSYSTEM = '1'
$scan = Join-Path $root 'bin/contract-scan.ps1'
$proj = Join-Path $t 'proj'

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -ceq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}
function Git-In($dir) { & git -C $dir -c user.name=check -c user.email=check@localhost @args 2>$null | Out-Null }
function Clone-WithOrigin($name, $file, $content) {
  & git init -q --bare (Join-Path $t "origin/$name.git")
  & git clone -q (Join-Path $t "origin/$name.git") (Join-Path $proj $name) 2>$null
  Set-Content -LiteralPath (Join-Path $proj "$name/$file") -Value $content
  Git-In (Join-Path $proj $name) add -A; Git-In (Join-Path $proj $name) commit -q -m init
  Git-In (Join-Path $proj $name) push -q origin HEAD; Git-In (Join-Path $proj $name) remote set-head origin -a
}
# Scan <dir> <args...>: the lines and the exit code of one run in its own process, as a caller sees them
function Scan($dir) {
  Push-Location $dir
  try { $lines = @(& pwsh -NoProfile -NonInteractive -File $scan @args 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
  finally { Pop-Location }
  [pscustomobject]@{ Lines = $lines; Code = $code }
}

New-Item -ItemType Directory -Path $proj -Force | Out-Null
Clone-WithOrigin 'shop-api' 'config.env' 'CATALOG_DIRS=webs'
Clone-WithOrigin 'shop-web' 'build.mjs' 'read(process.env.CATALOG_DIRS)'
Set-Content -LiteralPath (Join-Path $proj 'shop-web/many.txt') -Value (1..12 | ForEach-Object { "MANY $_" })
Git-In (Join-Path $proj 'shop-web') add -A; Git-In (Join-Path $proj 'shop-web') commit -q -m many; Git-In (Join-Path $proj 'shop-web') push -q origin HEAD
& git init -q (Join-Path $proj 'shop-docs')
Set-Content -LiteralPath (Join-Path $proj 'shop-docs/README.md') -Value 'DOCS_ONLY'
Git-In (Join-Path $proj 'shop-docs') add -A; Git-In (Join-Path $proj 'shop-docs') commit -q -m docs
New-Item -ItemType Directory -Path (Join-Path $proj 'notes') | Out-Null
Set-Content -LiteralPath (Join-Path $proj 'notes/todo.txt') -Value 'CATALOG_DIRS'
Set-Content -LiteralPath (Join-Path $proj 'shop-api/local.txt') -Value 'LOCAL_ONLY'
Git-In (Join-Path $proj 'shop-api') add -A; Git-In (Join-Path $proj 'shop-api') commit -q -m 'not pushed'
Set-Content -LiteralPath (Join-Path $proj 'shop-docs/draft.txt') -Value 'CATALOG_DIRS'

Write-Host 'the planted defect: the contract has a side outside the package'
$r = Scan (Join-Path $proj 'shop-web') -Package shop-web CATALOG_DIRS
Check 'it exits 3'       3 $r.Code
Check 'the count line'   'CATALOG_DIRS: 2 hit(s) in 2 of 3 repositories' $r.Lines[0]
Check 'the producer'     '  shop-api config.env:1:CATALOG_DIRS=webs' $r.Lines[1]
Check 'the reader'       '  shop-web build.mjs:1:read(process.env.CATALOG_DIRS)' $r.Lines[2]
Check 'the side outside' '  outside the package: shop-api (1)' $r.Lines[3]

Write-Host 'the planted innocent: both sides in the package, and the same from a subfolder'
New-Item -ItemType Directory -Path (Join-Path $proj 'shop-api/sub') | Out-Null
$r = Scan (Join-Path $proj 'shop-api/sub') -Package 'shop-web,shop-api' CATALOG_DIRS
Check 'it exits 0'      0 $r.Code
Check 'no side outside' 'False' ([bool]($r.Lines -match 'outside the package'))

Write-Host 'what ships, not what is local'
$r = Scan (Join-Path $proj 'shop-api') LOCAL_ONLY DOCS_ONLY
Check 'a commit not pushed' 'LOCAL_ONLY: 0 hit(s) in 0 of 3 repositories' $r.Lines[0]
Check 'HEAD without origin' 'DOCS_ONLY: 1 hit(s) in 1 of 3 repositories' $r.Lines[1]
Check 'its hit'             '  shop-docs README.md:1:DOCS_ONLY' $r.Lines[2]
Check 'without -Package'    0 $r.Code

Write-Host 'ten hits per repository, and the count of the rest'
$r = Scan (Join-Path $proj 'shop-web') MANY
Check 'the count line' 'MANY: 12 hit(s) in 1 of 3 repositories' $r.Lines[0]
Check 'ten lines'      10 @($r.Lines | Where-Object { $_.StartsWith('  shop-web many.txt:') }).Count
Check 'the rest'       '  shop-web ... and 2 more' $r.Lines[11]

Write-Host 'usage errors'
$r = Scan (Join-Path $proj 'shop-web') -Package shop-cms CATALOG_DIRS
Check 'a package repo that is no clone' '1 True' "$($r.Code) $([bool]($r.Lines -match [regex]::Escape('error: --package names shop-cms, which is no clone of')))"

Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
