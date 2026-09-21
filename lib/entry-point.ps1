#!/usr/bin/env pwsh
# NOT AN IMPLEMENTATION. What this repository checks is written once, in the bash file of the same
# name beside this one, and this is the Windows entry point that starts it. There is no second
# spelling of the checks left to drift from the first.
#
# THE FILE IT RUNS IS ITS OWN NAME with .sh instead of .ps1, so check.ps1 runs check.sh and
# build.ps1 runs build.sh. The name IS the rule, which is why this file is byte for byte the same
# in every repository of the organisation and why nothing here has to be edited per repository.
#
# BASH IS THE ONE GIT SHIPS, FOUND BESIDE git ITSELF. Every one of these repositories is a git
# checkout, so that bash is on the machine by definition, and it is also the one git runs a hook
# with. The name on the path is the fallback, and it is second on purpose: on a machine with the
# Linux subsystem installed, `bash` alone is a launcher that cannot read this tree at all.
$ErrorActionPreference = 'Continue'

# The verdict line the bash twin prints carries an em dash. Left on the machine's own code page,
# the console draws something else, and the one line a reader looks at then differs between the
# two ways of starting the same checks.
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$name = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)

$bash = $null
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
  $shipped = Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin/bash.exe'
  if (Test-Path -LiteralPath $shipped) { $bash = $shipped }
}
if (-not $bash) { $bash = (Get-Command bash -ErrorAction SilentlyContinue).Source }
if (-not $bash) {
  Write-Host "${name}: FAIL — no bash on this machine, and the checks are written in it. Git ships one; install git, or put a bash on PATH. Nothing was checked."
  exit 1
}

# A RED RUN STILL CARRIES THE VERDICT LINE THIS ENTRY POINT PROMISES. Handed a path that is not
# there, bash writes its own "No such file or directory" and exits 127, and a person reading for
# `check: FAIL — <step>` finds nothing at all.
$sh = Join-Path $PSScriptRoot "$name.sh"
if (-not (Test-Path -LiteralPath $sh)) {
  Write-Host "${name}: FAIL — $sh is missing, and it is where these checks are written. Nothing was checked."
  exit 1
}

& $bash $sh @args
exit $LASTEXITCODE
