# Install setup-ai-core on this machine, once: a clone (or the one you already have), its bin\
# on the PATH, and a first doctor run.
#
#   install.ps1 [-Source <clone>] [-Dir <path>] [-Repo <url>] [-NoPath] [-NoDoctor]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [string]$Source = "",
  [string]$Dir = "",
  [string]$Repo = "https://github.com/kartalbas/setup-ai-core",
  [switch]$NoPath,
  [switch]$NoDoctor
)

if ($Help -or $args -ccontains "-h" -or $args -ccontains "--help" -or $Source -ceq "--help" -or $Source -ceq "-h") {
  Write-Host "Usage: install.ps1 [-Source <clone>] [-Dir <path>] [-Repo <url>] [-NoPath] [-NoDoctor]"
  Write-Host ""
  Write-Host "Installs setup-ai-core on this machine, once: clones it to ~\setup-ai-core (or uses the"
  Write-Host "clone you already have), adds its bin\ directory, where the ai-core command lives, to the"
  Write-Host "user PATH, and runs doctor."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Source <clone>   Use this existing clone of setup-ai-core; nothing is cloned or linked"
  Write-Host "  -Dir <path>       Clone somewhere else than ~\setup-ai-core"
  Write-Host "  -Repo <url>       Clone from this URL or path instead of GitHub (a mirror, a fork)"
  Write-Host "  -NoPath           Do not touch the PATH"
  Write-Host "  -NoDoctor         Do not run doctor at the end"
  Write-Host "  -Help             Show this help message"
  exit 0
}

$ErrorActionPreference = 'Stop'

$isWin = $IsWindows -or $env:OS -ceq 'Windows_NT'
$dir = if ($Dir) { $Dir } else { Join-Path $HOME "setup-ai-core" }

# 1. The clone: the one named with -Source, or one at $dir, cloned when missing
if ($Source) {
  $dir = (Resolve-Path $Source).Path
  if (-not ((Test-Path (Join-Path $dir "VERSION")) -and (Test-Path (Join-Path $dir "templates")))) {
    Write-Host "error: $dir is not a clone of setup-ai-core" -ForegroundColor Red; exit 1
  }
  Write-Host "==> Using the clone at $dir"
} elseif (Test-Path (Join-Path $dir ".git")) {
  Write-Host "==> setup-ai-core is already at $dir; updating"
  & pwsh -NoProfile -File (Join-Path $dir "bin\update.ps1")
  if ($LASTEXITCODE -ne 0) { exit 1 }
} else {
  Write-Host "==> Cloning $Repo to $dir"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dir) | Out-Null
  & git clone --quiet $Repo $dir
  # The newest release, when there is one: what is not tagged reaches nobody
  $tag = "$(@(& git -C $dir tag --list 'v[0-9]*' --sort=-v:refname 2>$null | ForEach-Object { "$_" } | Where-Object { $_ })[0])"
  if ($tag) { & git -C $dir checkout --quiet $tag; Write-Host "==> release $tag" } else { Write-Host "==> no release yet; on $(& git -C $dir symbolic-ref --short -q HEAD)" }
  if ($LASTEXITCODE -ne 0) { exit 1 }
}

# 2. PATH: bin\ of the clone, where the ai-core command lives
$bin = Join-Path $dir "bin"
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
}
if (($env:Path -split [IO.Path]::PathSeparator) -notcontains $bin) { $env:Path = "$bin" + [IO.Path]::PathSeparator + $env:Path }

Write-Host "==> setup-ai-core $((Get-Content (Join-Path $dir 'VERSION') -Raw).Trim()) at $dir"

# 3. doctor
if (-not $NoDoctor) {
  Write-Host ""
  & pwsh -NoProfile -File (Join-Path $dir "bin\doctor.ps1")
  if ($LASTEXITCODE -ne 0) { Write-Host "install: setup-ai-core is installed; doctor found problems (above)."; exit 1 }
}
Write-Host "Next: cd into a repository and run 'ai-core init'."
