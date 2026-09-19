# Install the harness on this machine, once: the engine under ~\.ai-core\engine, the ai-core
# command under ~\.ai-core\bin, the PATH entry, and a first doctor run.
#
#   install.ps1 [-Engine <clone>] [-NoPath] [-NoDoctor]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [string]$Engine = "",
  [switch]$NoPath,
  [switch]$NoDoctor
)

if ($Help -or $args -contains "-h" -or $args -contains "--help" -or $Engine -eq "--help" -or $Engine -eq "-h") {
  Write-Host "Usage: install.ps1 [-Engine <clone>] [-NoPath] [-NoDoctor]"
  Write-Host ""
  Write-Host "Installs the harness on this machine, once. Clones the engine to `$env:AI_CORE_HOME\engine"
  Write-Host "(default ~\.ai-core\engine), puts the ai-core command into `$env:AI_CORE_HOME\bin, adds that"
  Write-Host "directory to the user PATH, and runs doctor."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Engine <clone>   Use an existing clone of setup-ai-core as the engine (a junction, no copy)"
  Write-Host "  -NoPath           Do not touch the PATH"
  Write-Host "  -NoDoctor         Do not run doctor at the end"
  Write-Host "  -Help             Show this help message"
  exit 0
}

$ErrorActionPreference = 'Stop'

$aiCoreHome = if ($env:AI_CORE_HOME) { $env:AI_CORE_HOME } else { Join-Path $HOME ".ai-core" }
$repoUrl = "https://github.com/kartalbas/setup-ai-core"
$isWin = $IsWindows -or $env:OS -eq 'Windows_NT'
$engineDir = Join-Path $aiCoreHome "engine"
$bin = Join-Path $aiCoreHome "bin"
New-Item -ItemType Directory -Force -Path $bin | Out-Null

Write-Host "==> Installing setup-ai-core under $aiCoreHome"

# 1. The engine: a link to an existing clone, or a fresh clone from GitHub
if ($Engine) {
  $src = (Resolve-Path $Engine).Path
  if (-not ((Test-Path (Join-Path $src "VERSION")) -and (Test-Path (Join-Path $src "templates")))) {
    Write-Host "error: $src is not a clone of setup-ai-core" -ForegroundColor Red; exit 1
  }
  if (Test-Path $engineDir) {
    $item = Get-Item $engineDir -Force
    if ($item.LinkType) { $item.Delete() }
    else { Write-Host "error: $engineDir exists and is not a link; remove it first or omit -Engine" -ForegroundColor Red; exit 1 }
  }
  if ($isWin) { New-Item -ItemType Junction -Path $engineDir -Target $src | Out-Null }
  else { New-Item -ItemType SymbolicLink -Path $engineDir -Target $src | Out-Null }
  Write-Host "--> Engine: $engineDir -> $src"
} elseif ((Test-Path (Join-Path $engineDir ".git")) -or ((Test-Path $engineDir) -and (Get-Item $engineDir -Force).LinkType)) {
  Write-Host "--> Engine already at $engineDir; pulling"
  & git -C $engineDir pull --ff-only
  if ($LASTEXITCODE -ne 0) { exit 1 }
} else {
  Write-Host "--> Cloning $repoUrl to $engineDir"
  & git clone --quiet $repoUrl $engineDir
  if ($LASTEXITCODE -ne 0) { exit 1 }
}

# 2. The command: thin launchers that resolve everything from the engine at run time
foreach ($f in @("ai-core", "ai-core.ps1", "ai-core.cmd")) { Copy-Item -Force (Join-Path $engineDir "bin\$f") (Join-Path $bin $f) }
Write-Host "--> Command: $(Join-Path $bin 'ai-core')"

# 3. PATH
if (-not $NoPath) {
  if ($isWin) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $bin) {
      [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $bin), 'User')
      Write-Host "--> PATH: added $bin to the user PATH (open a new terminal)"
    } else { Write-Host "--> PATH: already in the user PATH" }
  } else {
    $profileFile = Join-Path $HOME ".profile"
    $line = "export PATH=`"$bin`:`$PATH`"  # setup-ai-core"
    if (-not (Test-Path $profileFile) -or -not (Select-String -Path $profileFile -Pattern '# setup-ai-core' -SimpleMatch -Quiet)) {
      Add-Content -Path $profileFile -Value "`n$line"
      Write-Host "--> PATH: added $bin to ~/.profile (open a new terminal)"
    } else { Write-Host "--> PATH: already set in ~/.profile" }
  }
  if (($env:Path -split [IO.Path]::PathSeparator) -notcontains $bin) { $env:Path = "$bin" + [IO.Path]::PathSeparator + $env:Path }
}

Write-Host "==> Installed engine $((Get-Content (Join-Path $engineDir 'VERSION') -Raw).Trim())."

# 4. doctor
if (-not $NoDoctor) {
  Write-Host ""
  & pwsh -NoProfile -File (Join-Path $engineDir "bin\doctor.ps1")
  if ($LASTEXITCODE -ne 0) { Write-Host "install: the harness is installed; doctor found problems (above)."; exit 1 }
}
Write-Host "Next: cd into a repository and run 'ai-core init'."
