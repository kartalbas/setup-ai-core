# Install setup-ai-core on this machine, once: the clone at ~\.setup-ai-core, its bin\ on the
# PATH, and a first doctor run.
#
#   install.ps1 [-Source <clone>] [-Dir <path>] [-NoPath] [-NoDoctor]
#
[CmdletBinding()]
param (
  [switch]$Help,
  [string]$Source = "",
  [string]$Dir = "",
  [switch]$NoPath,
  [switch]$NoDoctor
)

if ($Help -or $args -contains "-h" -or $args -contains "--help" -or $Source -eq "--help" -or $Source -eq "-h") {
  Write-Host "Usage: install.ps1 [-Source <clone>] [-Dir <path>] [-NoPath] [-NoDoctor]"
  Write-Host ""
  Write-Host "Installs setup-ai-core on this machine, once: clones it to ~\.setup-ai-core, adds its bin\"
  Write-Host "directory (where the ai-core command lives) to the user PATH, and runs doctor."
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Source <clone>   Use an existing clone of setup-ai-core instead of cloning: ~\.setup-ai-core becomes a junction to it"
  Write-Host "  -Dir <path>       Install somewhere else than ~\.setup-ai-core"
  Write-Host "  -NoPath           Do not touch the PATH"
  Write-Host "  -NoDoctor         Do not run doctor at the end"
  Write-Host "  -Help             Show this help message"
  exit 0
}

$ErrorActionPreference = 'Stop'

$repoUrl = "https://github.com/kartalbas/setup-ai-core"
$isWin = $IsWindows -or $env:OS -eq 'Windows_NT'
$dir = if ($Dir) { $Dir } else { Join-Path $HOME ".setup-ai-core" }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dir) | Out-Null

Write-Host "==> Installing setup-ai-core at $dir"

# 1. The clone: a link to an existing one, or a fresh clone from GitHub
if ($Source) {
  $src = (Resolve-Path $Source).Path
  if (-not ((Test-Path (Join-Path $src "VERSION")) -and (Test-Path (Join-Path $src "templates")))) {
    Write-Host "error: $src is not a clone of setup-ai-core" -ForegroundColor Red; exit 1
  }
  if (Test-Path $dir) {
    $item = Get-Item $dir -Force
    if ($item.LinkType) { $item.Delete() }
    else { Write-Host "error: $dir exists and is not a link; remove it first or omit -Source" -ForegroundColor Red; exit 1 }
  }
  if ($isWin) { New-Item -ItemType Junction -Path $dir -Target $src | Out-Null }
  else { New-Item -ItemType SymbolicLink -Path $dir -Target $src | Out-Null }
  Write-Host "--> $dir -> $src"
} elseif ((Test-Path (Join-Path $dir ".git")) -or ((Test-Path $dir) -and (Get-Item $dir -Force).LinkType)) {
  Write-Host "--> Already at $dir; pulling"
  & git -C $dir pull --ff-only
  if ($LASTEXITCODE -ne 0) { exit 1 }
} else {
  Write-Host "--> Cloning $repoUrl"
  & git clone --quiet $repoUrl $dir
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

Write-Host "==> Installed setup-ai-core $((Get-Content (Join-Path $dir 'VERSION') -Raw).Trim())."

# 3. doctor
if (-not $NoDoctor) {
  Write-Host ""
  & pwsh -NoProfile -File (Join-Path $dir "bin\doctor.ps1")
  if ($LASTEXITCODE -ne 0) { Write-Host "install: setup-ai-core is installed; doctor found problems (above)."; exit 1 }
}
Write-Host "Next: cd into a repository and run 'ai-core init'."
