# The PowerShell twin of usage.test.sh: what the status line records of the account's usage windows,
# and what usage makes of it. HOME and AI_CORE_HOME point into a temporary folder.
#
#   pwsh -File tests/usage.test.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) "usage-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$project = Join-Path $work 'project'
New-Item -ItemType Directory -Force -Path (Join-Path $work 'home'), $project | Out-Null
$keptHome = $env:HOME; $keptProfile = $env:USERPROFILE
$env:HOME = Join-Path $work 'home'; $env:USERPROFILE = $env:HOME; $env:AI_CORE_HOME = $env:HOME
$record = Join-Path $env:HOME '.ai-core/usage.json'
Remove-Item Env:CODEX_THREAD_ID, Env:CODEX_SANDBOX, Env:CODEX_SANDBOX_NETWORK_DISABLED, Env:CODEX_HOME -ErrorAction SilentlyContinue   # the Claude Code cases run as no Codex shell

$failed = 0
function Check($name, $expected, $actual) {
  if ("$expected" -ceq "$actual") { Write-Host "  ok   $name" }
  else { Write-Host "  FAIL $name`n       expected: [$expected]`n       actual:   [$actual]"; $script:failed++ }
}
function When([long]$t) { [DateTimeOffset]::FromUnixTimeSeconds($t).ToLocalTime().ToString('ddd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
function Run([string]$script, [string[]]$arguments, [string]$stdin = '') {
  Push-Location $project
  try {
    $script:out = (@($stdin | & pwsh -NoProfile -File (Join-Path $root "bin/$script") @arguments 2>&1 | ForEach-Object { "$_" }) -join "`n")
    $script:rc = $LASTEXITCODE
  } finally { Pop-Location }
}
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $soon = $now + 3600; $later = $now + 86400
$state = "{`"model`":{`"display_name`":`"Opus`"},`"rate_limits`":{`"five_hour`":{`"used_percentage`":42.7,`"resets_at`":$soon},`"seven_day`":{`"used_percentage`":95.1,`"resets_at`":$later}}}"

try {
  Write-Host 'the status line records the windows and shows the model and the windows'
  Run 'statusline.ps1' @() $state
  Check 'the line'               'Opus · 5h 42 % · week 95 %' $out
  $r = Get-Content -Raw -LiteralPath $record | ConvertFrom-Json
  Check 'the windows recorded'   '42.7 95.1' "$($r.rate_limits.five_hour.used_percentage.ToString([Globalization.CultureInfo]::InvariantCulture)) $($r.rate_limits.seven_day.used_percentage.ToString([Globalization.CultureInfo]::InvariantCulture))"
  Run 'statusline.ps1' @() $state   # a second run within the minute adds no line to the history
  $history = @(Get-Content -LiteralPath (Join-Path (Split-Path -Parent $record) 'usage.log'))
  Check 'the history, one line a minute' "1 42.7 $soon 95.1 $later" "$($history.Count) $(($history[0] -split ' ', 2)[1])"

  Write-Host 'usage at the limit: every window named, and exit 3'
  Run 'usage.ps1' @()
  Check 'exit 3'                 3 $rc
  $lines = $out -split "`n"
  Check 'the five hours'         "five_hour   42 %  resets $(When $soon)" $lines[0]
  Check 'the week'               "seven_day   95 %  resets $(When $later)" $lines[1]
  Check 'what to do'             'True' ([bool]($out -cmatch '(?m)^a window stands at 92 % or more: finish the step in hand'))
  Write-Host 'below a limit given: exit 0'
  Run 'usage.ps1' @('-StopAt', '96')
  Check 'exit 0'                 0 $rc
  Write-Host "the project's own limit: USAGE_STOP_AT in its config.env"
  New-Item -ItemType Directory -Force -Path (Join-Path $project '.ai-core') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $project '.ai-core/config.env'), "USAGE_STOP_AT=`"96`"`n")
  Run 'usage.ps1' @()
  Check 'exit 0 at 95 % under 96' 0 $rc
  Check 'it names the limit'     'True' ([bool]($out -cmatch ', limit 96 %$'))
  Remove-Item -LiteralPath (Join-Path $project '.ai-core/config.env')
  Write-Host 'a window whose reset has passed counts as reset'
  [System.IO.File]::WriteAllText($record, "{`"recorded_at`":$now,`"rate_limits`":{`"five_hour`":{`"used_percentage`":99,`"resets_at`":$($now - 60)}}}`n")
  Run 'usage.ps1' @()
  Check 'exit 0'                 0 $rc
  Check 'reported as reset'      "five_hour    0 %  reset since $(When ($now - 60))" (($out -split "`n")[0])
  Write-Host 'nothing recorded: exit 2, and why'
  Remove-Item -LiteralPath $record
  Run 'usage.ps1' @()
  Check 'exit 2'                 2 $rc
  Check 'it says why'            'True' ([bool]($out -cmatch 'no usage recorded yet'))

  Write-Host "in a Codex shell: the windows Codex wrote last into its newest session file, never Claude's"
  Set-Content -LiteralPath $record -Value "{`"recorded_at`":$now,`"rate_limits`":{`"seven_day`":{`"used_percentage`":99,`"resets_at`":$later}}}" -Encoding utf8NoBOM
  $sessions = Join-Path $env:HOME '.codex/sessions/2026/10/13'; New-Item -ItemType Directory -Path $sessions -Force | Out-Null
  function CodexLine($used, $secondary) { "{`"timestamp`":`"2026-10-13T07:09:45.777Z`",`"type`":`"event_msg`",`"payload`":{`"type`":`"token_count`",`"rate_limits`":{`"limit_id`":`"codex`",`"primary`":{`"used_percent`":$used,`"window_minutes`":10080,`"resets_at`":$later},`"secondary`":$secondary}}}" }
  $old = Join-Path $sessions 'rollout-old.jsonl'; Set-Content -LiteralPath $old -Value (CodexLine 99 'null') -Encoding utf8NoBOM
  (Get-Item -LiteralPath $old).LastWriteTime = [datetime]'2026-01-01'
  $new = Join-Path $sessions 'rollout-new.jsonl'
  Set-Content -LiteralPath $new -Encoding utf8NoBOM -Value @((CodexLine 3 'null'), (CodexLine 7 "{`"used_percent`":12.5,`"window_minutes`":300,`"resets_at`":$soon}"),
    '{"timestamp":"2026-10-13T07:10:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}')
  $env:CODEX_THREAD_ID = 't'; Run 'usage.ps1' @(); $env:CODEX_THREAD_ID = $null
  $lines = $out -split "`n"
  Check 'exit 0, Claude at 99 % does not count' 0 $rc
  Check 'the week'               "seven_day    7 %  resets $(When $later)" $lines[0]
  Check 'the five hours'         "five_hour   12 %  resets $(When $soon)" $lines[1]
  Check 'when Codex recorded it' "recorded $(When ([DateTimeOffset]::Parse('2026-10-13T07:09:45Z').ToUnixTimeSeconds())), limit 92 %" $lines[2]
  Run 'usage.ps1' @()
  Check 'no Codex shell: Claude at 99 %, exit 3' 3 $rc
  Add-Content -LiteralPath $new -Value (CodexLine 95 'null') -Encoding utf8NoBOM
  $env:CODEX_THREAD_ID = 't'; Run 'usage.ps1' @(); $env:CODEX_THREAD_ID = $null
  Check 'Codex at its limit: exit 3' 3 $rc
  Remove-Item -Recurse -Force (Join-Path $env:HOME '.codex')
  $env:CODEX_THREAD_ID = 't'; Run 'usage.ps1' @(); $env:CODEX_THREAD_ID = $null
  Check 'no Codex session file: exit 2' 2 $rc
  Check 'it says why'            'True' ([bool]($out -cmatch 'no usage recorded yet: Codex records it'))
} finally {
  $env:HOME = $keptHome; $env:USERPROFILE = $keptProfile; $env:AI_CORE_HOME = $null
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
if ($failed -gt 0) { Write-Host "`n$failed failed"; exit 1 }
Write-Host "`nall passed"
