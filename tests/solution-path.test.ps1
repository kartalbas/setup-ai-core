# The PowerShell twin of solution-path.test.sh, asserting the SAME eight headings, the SAME
# refusals and the SAME file-as-a-file post.
#
#   pwsh -File test/solution-path.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'https://github.com/example-org/example-repo/issues/163#issuecomment-1'
exit 0
"@ | Set-Content -Path (Join-Path $fake 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$fake\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $fake 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $fake 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$fake/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $fake 'gh') }
$env:PATH = "$fake;$env:PATH"

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -eq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: $expected`n       actual:   $actual"; $script:failed++ }
}

$path = Join-Path $root 'bin/solution-path.ps1'
$whole = Join-Path $fake 'whole.md'
function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }
$errFile = Join-Path $fake 'stderr.txt'

# Every required heading, with the options written as sub-headings - a deeper heading stands
# INSIDE its section and neither opens a new one nor ends the one it is in.
@'
# Solution path

## Where a person meets this
On the board, the first time a card is read after a push.

## What they see today
The card still says implementing, and the work is on master.

## What the system does behind it
Nothing reads the commit; the column is only ever set by hand.

## The decision
Whether the sweep reads a pull request or a commit on master.

## Options
### It reads the commit on master
One signal, and it is the one the push hook already lets through.
### It reads an open worktree
A worktree is a place to commit, not a statement that anything is finished.

## Recommendation
It reads the commit on master.

## Code facts
`bin/status-sync.ps1:42` is where the signals are derived.

## Reuse manifest
`lib/Board.psm1` Get-BoardItems and `bin/board-list.ps1`.
'@ | Set-Content -Path $whole -Encoding utf8NoBOM

Write-Host 'a finished path is checked and posts nothing with -Check'
Clear-Log
$out = @(& $path -Number 163 -File $whole -Check)
Check 'every section' "$whole carries all 8 sections." $out[0]
Check 'and says so'   'Checked only - nothing was posted.' $out[1]
Check 'nothing sent'  0 (Calls).Count

Write-Host 'without -Check the file travels as a file'
Clear-Log
$out = @(& $path -Number 163 -File $whole)
Check 'the flag'        'True'  ([bool]((Calls) -match [regex]::Escape("--body-file $whole")))
Check 'no inline body'  'False' ([bool]((Calls) -match '--body '))
Check 'what gh printed' 'https://github.com/example-org/example-repo/issues/163#issuecomment-1' $out[-1]

Write-Host 'a heading that is not there is named, and nothing is sent'
$short = Join-Path $fake 'short.md'
(Get-Content $whole | Where-Object { $_ -ne '## Options' -and $_ -ne '## Reuse manifest' }) |
  Set-Content -Path $short -Encoding utf8NoBOM
Clear-Log
$said = ''
try { & $path -Number 163 -File $short 2>$null | Out-Null } catch { $said = $_.Exception.Message }
Check 'it throws'    'True' ([bool]($said -match 'write those sections'))
Check 'nothing sent' 0      (Calls).Count

Write-Host 'a heading with nothing under it is named too'
$hollow = Join-Path $fake 'hollow.md'
(Get-Content $whole) -replace '^It reads the commit on master\.$', '' | Set-Content -Path $hollow -Encoding utf8NoBOM
Clear-Log
# The named sections go out on the ERROR stream and the run then throws, so the stream is
# redirected to a FILE: a pipeline that is aborted by the throw never assigns its variable.
$said = ''
try { & $path -Number 163 -File $hollow 2>$errFile | Out-Null } catch { $said = $_.Exception.Message }
$reported = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
Check 'it throws'     'True' ([bool]($said -match 'write those sections'))
Check 'the empty one' 'True' ([bool]($reported -match 'leaves "Recommendation" empty'))
Check 'nothing sent'  0      (Calls).Count

# A heading that stands twice has two bodies and only one of them is ever read - the first in
# one shell, the last in the other - so the same file was accepted by one twin and refused by
# the other.
Write-Host 'a heading that stands twice is refused, and nothing is sent'
$doubled = Join-Path $fake 'doubled.md'
((Get-Content $whole) + '' + '## Options') | Set-Content -Path $doubled -Encoding utf8NoBOM
Clear-Log
$said = ''
try { & $path -Number 163 -File $doubled 2>$errFile | Out-Null } catch { $said = $_.Exception.Message }
$reported = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
Check 'it throws'            'True' ([bool]($said -match 'a required heading may stand only once'))
Check 'it names the heading' 'True' ([bool]($reported -match 'names "## Options" twice'))
Check 'nothing sent'         0      (Calls).Count

Write-Host 'a file that is not there stops before anything is read'
Clear-Log
$said = ''
try { & $path -Number 163 -File (Join-Path $fake 'nope.md') | Out-Null } catch { $said = $_.Exception.Message }
Check 'the file is named' 'True' ([bool]($said -match 'there is no file at'))
Check 'nothing sent'      0      (Calls).Count

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
