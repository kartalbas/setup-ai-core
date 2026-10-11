<#
.SYNOPSIS
Where a contract stands across the repositories of the project: the file:line of each term in
every repository, and with -Package the repositories outside the package that hold one.

.DESCRIPTION
  contract-scan.ps1 TERM...                          each term's hits, repository by repository
  contract-scan.ps1 -Package REPO,REPO... TERM...    and exit 3 where a repository outside the
                                                     package holds a hit

A CONTRACT IS WHAT ONE REPOSITORY READS AND ANOTHER SHIPS: a file name, a manifest field, a
configuration key, an environment variable, a route. A package cut by file or module splits it
where reader and producer sit in two repositories, and the two then release apart. The planner
names the terms the package's issues touch; this prints where each one stands, so both sides
join the package, and the plan check runs it with the package's repositories.

THE TREE SEARCHED IS WHAT SHIPS: the default branch of origin as the clone last fetched it
(origin/HEAD), else the clone's HEAD; never a working tree with somebody's edits. The search is
literal, `git grep -F`. The repositories are the git clones directly in the project folder (the
folder holding the clone this runs in, or the current directory); REPO is a clone's folder name.
Up to 10 hits per repository and term are printed, with the count of all of them.

Exit 0: no -Package, or every hit lies inside it. Exit 3: a term has a hit outside the package.
Exit 1: a usage error, or a REPO of -Package that is no clone of the project folder.
#>
[CmdletBinding()]
param(
  [string] $Package,
  [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)][string[]] $Term
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

$withPackage = $PSBoundParameters.ContainsKey('Package')
$folder = Get-ProjectFolder
[string[]] $repos = @(Get-ChildItem -Directory -LiteralPath $folder | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
  ForEach-Object { $_.Name })
[Array]::Sort($repos, [StringComparer]::Ordinal)
if ($repos.Count -eq 0) { Stop-WithError "no git clone in $folder" }

$inside = @()
if ($withPackage) {
  $inside = @($Package -split ',' | Where-Object { $_ })
  foreach ($p in $inside) { if ($repos -cnotcontains $p) { Stop-WithError "--package names $p, which is no clone of $folder" } }
}

$outside = $false
foreach ($t in $Term) {
  $total = 0; $holders = 0; $lines = @(); $foreign = ''
  foreach ($r in $repos) {
    $dir = Join-Path $folder $r
    $ref = 'HEAD'
    & git -C $dir rev-parse --verify -q refs/remotes/origin/HEAD *> $null
    if ($LASTEXITCODE -eq 0) { $ref = 'origin/HEAD' }
    $hits = @(& git -C $dir grep -n -I -F -e $t $ref -- 2>$null | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ })
    if ($hits.Count -eq 0) { continue }
    $total += $hits.Count; $holders++
    foreach ($h in ($hits | Select-Object -First 10)) {
      $line = "  $r $($h.Substring($ref.Length + 1))"
      $lines += if ($line.Length -gt 200) { $line.Substring(0, 200) } else { $line }
    }
    if ($hits.Count -gt 10) { $lines += "  $r ... and $($hits.Count - 10) more" }
    if ($withPackage -and $inside -cnotcontains $r) { $foreign += " $r ($($hits.Count))" }
  }
  "${t}: $total hit(s) in $holders of $($repos.Count) repositories"
  $lines
  if ($foreign) { "  outside the package:$foreign"; $outside = $true }
}
if ($outside) { exit 3 }
exit 0
