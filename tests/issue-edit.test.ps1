# The PowerShell twin of issue-edit.test.sh, asserting the SAME call shape and the SAME refusals.
#
# AND THE ASKED-FOR LINE SURVIVES THE EDIT, which is the reason the fake answers a READ as well
# as recording the write: the issue's own first line is what gets put back, so a test that could
# not answer that read could not tell keeping the line from composing one.
#
#   pwsh -File test/issue-edit.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fake = Join-Path ([IO.Path]::GetTempPath()) "gh-fake-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fake | Out-Null
$log = Join-Path $fake 'calls.txt'
# What the fake answers a read with, and where it keeps the body file it was handed - the tool
# deletes its temporary body the moment the call returns, so a copy is the only way to see it.
$reply = Join-Path $fake 'reply.txt'; Set-Content -Path $reply -Value '{}' -Encoding utf8NoBOM
$sent = Join-Path $fake 'sent-body.md'

@"
`$a = `$args -join ' '
Add-Content -Path '$log' -Value `$a
if (`$args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
if (`$a -match '--method PATCH') {
  foreach (`$one in `$args) { if (`$one -like 'body=@*') { Copy-Item `$one.Substring(6) '$sent' -Force } }
  '{}'
  exit 0
}
Get-Content -LiteralPath '$reply'
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

$edit = Join-Path $root 'bin/issue-edit.ps1'
$repo = 'example-org/example-repo'
$body = Join-Path $fake 'body.md'
'A body with a `backtick` in it.' | Set-Content $body -Encoding utf8NoBOM

function Calls { @(Get-Content $log -ErrorAction SilentlyContinue) }
function Clear-Log { Remove-Item $log -ErrorAction SilentlyContinue }

Write-Host 'a title alone sends the title and nothing else'
Clear-Log
$out = (@(& $edit -Repo $repo -Number 163 -Title 'Read the board whole, or the count is a guess') -join "`n")
Check 'what it says' '#163 -> edited (title)' $out
Check 'the method'   'True'  ([bool]((Calls) -match [regex]::Escape("api --method PATCH repos/$repo/issues/163")))
Check 'the title'    'True'  ([bool]((Calls) -match 'title=Read the board whole'))
Check 'no body sent' 'False' ([bool]((Calls) -match 'body='))
Check 'the issue is not read' 'False' ([bool]((Calls) -match '--jq \.body'))

Write-Host 'a body alone travels as a file reference'
Clear-Log
$out = (@(& $edit -Repo $repo -Number 163 -BodyFile $body) -join "`n")
Check 'what it says'    '#163 -> edited (body)' $out
Check 'the file'        'True'  ([bool]((Calls) -match [regex]::Escape("body=@$body")))
Check 'no title sent'   'False' ([bool]((Calls) -match 'title='))
Check 'not its content' 'False' ([bool]((Calls) -match 'backtick'))

Write-Host 'both together are one call'
Clear-Log
$out = (@(& $edit -Repo $repo -Number 163 -Title t -BodyFile $body) -join "`n")
Check 'what it says' '#163 -> edited (title and body)' $out
Check 'one PATCH'    1 @((Calls) | Where-Object { $_ -match 'api --method PATCH' }).Count

Write-Host 'the repo resolves from the checkout when left out'
Clear-Log
& $edit -Number 163 -Title t | Out-Null
Check 'default repo' 'True' ([bool]((Calls) -match [regex]::Escape("repos/$repo/issues/163")))

# THE ASKED-FOR LINE. The three cases below are the whole guarantee: a body without it, a body
# with it, and an issue that never had one.
$asked = 'Asked for by @kartalbas on 2026-09-04 in the chat session of 2026-09-04.'
$plain = Join-Path $fake 'plain.md'
'A rewritten body.' | Set-Content $plain -Encoding utf8NoBOM
$carrying = Join-Path $fake 'carrying.md'
Set-Content -Path $carrying -Value "$asked`n`nA rewritten body." -Encoding utf8NoBOM
function Clear-Sent { Remove-Item $sent -ErrorAction SilentlyContinue }
function Sent { @(Get-Content $sent -ErrorAction SilentlyContinue) }

Write-Host 'a body without the asked-for line keeps the line the issue carries'
Clear-Log; Clear-Sent
Set-Content -Path $reply -Value "$asked`n`nthe old body" -Encoding utf8NoBOM
$out = (@(& $edit -Repo $repo -Number 163 -BodyFile $plain) -join "`n")
Check 'what it says'      '#163 -> edited (body, asked-for line kept)' $out
Check 'the issue is read' 'True' ([bool]((Calls) -match '--jq \.body'))
Check 'the line is back on top' $asked (Sent)[0]
Check 'the new body follows'    'A rewritten body.' (Sent)[2]
Check 'one copy of the line'    1 @((Sent) | Where-Object { $_ -match 'Asked for by' }).Count
Check "the caller's file is left as it was" 'A rewritten body.' ((Get-Content $plain) -join "`n")
Check 'the caller path is not the one sent' 'False' ([bool]((Calls) -match [regex]::Escape("body=@$plain")))

Write-Host 'a body that already carries the line is sent untouched, and the issue is never read'
Clear-Log; Clear-Sent
$out = (@(& $edit -Repo $repo -Number 163 -BodyFile $carrying) -join "`n")
Check 'what it says'          '#163 -> edited (body)' $out
Check 'the issue is not read' 'False' ([bool]((Calls) -match '--jq \.body'))
Check 'the file itself'       'True'  ([bool]((Calls) -match [regex]::Escape("body=@$carrying")))
Check 'no second copy of the line' 1 @((Sent) | Where-Object { $_ -match 'Asked for by' }).Count

Write-Host 'an issue carrying no asked-for line is reported, and the body goes as given'
Clear-Log; Clear-Sent
Set-Content -Path $reply -Value 'An issue opened on the web.' -Encoding utf8NoBOM
$told = (@(& $edit -Repo $repo -Number 163 -BodyFile $plain 6>&1) | ForEach-Object { "$_" }) -join "`n"
Check 'says there is none to keep' 'True' ([bool]($told -match 'carries no asked-for line'))
Check 'the edit still happened'    'True' ([bool]($told -match [regex]::Escape('#163 -> edited (body)')))
Check 'the file itself'            'True' ([bool]((Calls) -match [regex]::Escape("body=@$plain")))
Set-Content -Path $reply -Value '{}' -Encoding utf8NoBOM

Write-Host 'an edit that changes nothing stops before GitHub is reached'
Clear-Log
$said = ''
try { & $edit -Repo $repo -Number 163 | Out-Null } catch { $said = $_.Exception.Message }
Check 'it throws'         'True' ([bool]($said -match 'an edit that changes nothing is a mistake'))
Check 'nothing sent'      0      (Calls).Count

Write-Host 'a body file that is not there stops before GitHub is reached'
Clear-Log
$said = ''
try { & $edit -Repo $repo -Number 163 -BodyFile (Join-Path $fake 'nope.md') | Out-Null } catch { $said = $_.Exception.Message }
Check 'the file is named' 'True' ([bool]($said -match 'does not exist'))
Check 'nothing sent'      0      (Calls).Count

Write-Host 'a parameter name the script does not have is refused by the binder'
Clear-Log
$said = ''
try { & $edit -Repo $repo -Number 163 -Titel t | Out-Null } catch { $said = $_.Exception.Message }
Check 'it throws'    'True' ([bool]($said -match 'Titel'))
Check 'nothing sent' 0      (Calls).Count

# The one failure mode keeping the line adds: the read before the write. It stops the edit,
# because the other way out is sending a body known to be missing the line.
Write-Host 'a refused READ stops the edit rather than sending the body without the line'
$refusing = Join-Path $fake 'refusing'
New-Item -ItemType Directory -Path $refusing | Out-Null
@"
if (`$args[0] -eq 'repo') { 'example-org/example-repo'; exit 0 }
'{"message":"Validation Failed"}'
[Console]::Error.WriteLine('gh: HTTP 422')
exit 1
"@ | Set-Content -Path (Join-Path $refusing 'gh.ps1') -Encoding utf8NoBOM
"@echo off`r`npwsh -NoProfile -File `"$refusing\gh.ps1`" %*" |
  Set-Content -Path (Join-Path $refusing 'gh.cmd') -Encoding ascii
if (-not $IsWindows) { Set-Content -Path (Join-Path $refusing 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"$refusing/gh.ps1`" `"`$@`"" -Encoding ascii; & chmod +x (Join-Path $refusing 'gh') }
$kept = $env:PATH
$env:PATH = "$refusing;$env:PATH"
$said = ''
try { $out = (@(& $edit -Repo $repo -Number 163 -BodyFile $plain) -join "`n") } catch { $said = $_.Exception.Message; $out = '' }
$env:PATH = $kept
Check 'it throws'        'True'  ([bool]($said -match [regex]::Escape("repos/$repo/issues/163")))
Check 'no edited line'   'False' ([bool]($out -match '-> edited'))

Remove-Item -Recurse -Force $fake -ErrorAction SilentlyContinue
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
