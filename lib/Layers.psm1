# The project harness of a checkout: where it is on GitHub, where its clone is on this machine,
# and the chain of harnesses it extends. Imported by init, push, update and session-start. The
# twin of lib/layers.sh; the comments there say why each rule stands.
#
# THE NAME COMES FROM THE REPOSITORY, nothing is configured: a checkout whose origin is
# github.com/<org>/<repo> belongs to github.com/<org>/<prefix>-ai-core, prefix being the repository
# name up to its first dash. THE CLONE LIES BESIDE THE REPOSITORIES IT SERVES, in the project
# folder, visible; a clone an earlier version put into ~\.<name>-ai-core is moved there. Its
# origin is checked against the name. EVERYTHING GITHUB-SIDE GOES THROUGH gh, which is what lets
# a test stand a fake gh on the PATH. A harness may extend another, ai-core.json
# {"extends": "<org>/<name>-ai-core"}; the chain is resolved base first, a circle or more than
# eight layers is refused.

$ErrorActionPreference = 'Stop'

function Get-OriginParts {
  # "<org>", "<repo>" from the origin of the checkout, or nothing when it has no origin on github.com
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Checkout)
  $url = & git -C $Checkout remote get-url origin 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $url) { return $null }
  $url = "$url".Trim().TrimEnd('/')
  if ($url.EndsWith('.git', [StringComparison]::Ordinal)) { $url = $url.Substring(0, $url.Length - 4) }
  $m = [regex]::Match($url, 'github\.com[:/]([^/]+)/([^/]+)$')
  if (-not $m.Success) { return $null }
  return @($m.Groups[1].Value, $m.Groups[2].Value)
}

function Get-HarnessOf {
  # the prefix, or nothing for setup-ai-core and for a harness itself
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Repo)
  if ($Repo -ceq 'setup-ai-core') { return $null }
  if ($Repo.EndsWith('-ai-core', [StringComparison]::Ordinal)) { return $null }
  $i = $Repo.IndexOf('-')
  if ($i -gt 0) { return $Repo.Substring(0, $i) }
  return $Repo
}

function Get-ProjectFolderOf {
  # The folder that holds the repositories: for a checkout the parent of its main checkout (a
  # worktree's too), for a directory that is no checkout the directory itself
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Directory)
  $common = "$(& git -C $Directory rev-parse --git-common-dir 2>$null)".Trim()
  if ($LASTEXITCODE -ne 0 -or -not $common) { return (Resolve-Path $Directory).Path }
  if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $Directory $common }
  $main = (Resolve-Path (Join-Path $common '..')).Path
  return Split-Path -Parent $main
}

function Get-LayerDir {
  # the clone, beside the repositories of the folder
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Full, [Parameter(Mandatory)][string]$Folder)
  Join-Path $Folder (($Full -split '/', 2)[1])
}

function Test-SameBytes([string]$a, [string]$b) {
  $x = [System.IO.File]::ReadAllBytes($a); $y = [System.IO.File]::ReadAllBytes($b)
  return ($x.Length -eq $y.Length) -and [System.Linq.Enumerable]::SequenceEqual($x, $y)
}

function Move-Layer {
  # The clone an earlier version kept under the home directory goes beside the repositories:
  # copied file by file, never over a file already there, so a move that was interrupted (the
  # history here, the files still there) is completed by the next run; the old directory goes
  # once every file of it is here unchanged. Move-Item is not used: across volumes it copies and
  # then fails on the hidden .git directory, halfway.
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Full, [Parameter(Mandatory)][string]$Old, [Parameter(Mandatory)][string]$New)
  $oldLong = (Get-Item -LiteralPath $Old -Force).FullName.TrimEnd('\', '/')
  New-Item -ItemType Directory -Force -Path $New | Out-Null
  $files = @(Get-ChildItem -LiteralPath $oldLong -Recurse -Force -File)
  foreach ($f in $files) {
    $to = Join-Path $New $f.FullName.Substring($oldLong.Length + 1)
    if (Test-Path -LiteralPath $to) { continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $to
  }
  $whole = $true
  foreach ($f in $files) {
    $to = Join-Path $New $f.FullName.Substring($oldLong.Length + 1)
    if (-not (Test-Path -LiteralPath $to) -or -not (Test-SameBytes $f.FullName $to)) { $whole = $false; break }
  }
  & git -C $New rev-parse --verify HEAD 2>$null | Out-Null
  if (-not $whole -or $LASTEXITCODE -ne 0) { throw "$Full is not whole at $New after the move from ${Old}; both directories stay" }
  Remove-Item -LiteralPath $Old -Recurse -Force
  Write-Host "moved: $Full from $Old to $New, beside the repositories it serves"
}

function Add-LayerAttributes {
  # A clone made before the skeleton carried .gitattributes gets the skeleton's rule, so every
  # checkout of it is LF (the .githooks shims run through bash, a .tsv keeps its last field); the
  # next ai-core push commits it
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Full, [switch]$Dry)
  $path = Join-Path $Dir '.gitattributes'
  $rule = '* text=auto eol=lf'
  if ((Test-Path $path) -and (@([System.IO.File]::ReadAllLines($path)) -ccontains $rule)) { return }
  if ($Dry) { Write-Host "note: $Full would get the skeleton's .gitattributes (every file LF; dry run: not written)"; return }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  if (Test-Path $path) {
    $text = [System.IO.File]::ReadAllText($path)
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n", [StringComparison]::Ordinal)) { $text += "`n" }
    [System.IO.File]::WriteAllText($path, $text + $rule + "`n", $utf8)
  } else {
    Copy-Item (Join-Path $Root 'skeleton\.gitattributes') $path
  }
  Write-Host "note: ${Full}: .gitattributes from the skeleton written into $Dir (every file LF); ai-core push commits it"
}

function Resolve-Layer {
  # The clone is there and current, or is moved from the home directory, or is cloned, or is
  # created from the skeleton with -Create; -Dry moves and creates nothing. Returns the clone
  # directory; throws when it cannot be had.
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Full, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Folder, [switch]$Create, [switch]$Dry)
  $dir = Get-LayerDir -Full $Full -Folder $Folder
  $old = Join-Path $HOME (".{0}" -f ($Full -split '/', 2)[1])
  if (Test-Path (Join-Path $old '.git')) {
    if ($Dry) {
      Write-Host "note: $Full would be moved from $old to $dir, beside the repositories it serves (dry run: not moved)"
      if (-not (Test-Path (Join-Path $dir '.git'))) { $dir = $old }
    } else { Move-Layer -Full $Full -Old $old -New $dir }
  }
  if (Test-Path (Join-Path $dir '.git')) {
    $origin = "$(& git -C $dir remote get-url origin 2>$null)".Trim()
    $o = $origin; if ($o.EndsWith('.git', [StringComparison]::Ordinal)) { $o = $o.Substring(0, $o.Length - 4) }
    if (-not ($o -cmatch ('github\.com[:/]' + [regex]::Escape($Full) + '$'))) { throw "$dir is a clone of $(if ($origin) { $origin } else { 'nothing' }), not of ${Full}; move it away" }
    # A working tree that lost every tracked file (an interrupted move, cleaned up by hand) is
    # checked out again from its history
    $tracked = @(& git -C $dir ls-files 2>$null | Where-Object { $_ }).Count
    $missing = @(& git -C $dir status --porcelain 2>$null | Where-Object { "$_".StartsWith(' D', [StringComparison]::Ordinal) }).Count
    if ($tracked -gt 0 -and $missing -eq $tracked) { & git -C $dir checkout -- . 2>$null | Out-Null; Write-Host "restored: the files of $Full at $dir from its history (every tracked file was missing)" }
    & git -C $dir pull --ff-only --quiet 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "note: could not pull $Full into $dir (offline, or the clone has local changes); using it as it is" }
    Add-LayerAttributes -Dir $dir -Root $Root -Full $Full -Dry:$Dry
    return $dir
  }
  & gh repo view $Full --json name 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    if ($Dry) { return $dir }
    & gh repo clone $Full $dir -- --quiet 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not clone $Full to $dir" }
    Add-LayerAttributes -Dir $dir -Root $Root -Full $Full
    return $dir
  }
  if (-not $Create) { throw "$Full does not exist on GitHub" }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item -Recurse -Force (Join-Path $Root 'skeleton\*') $dir
  foreach ($f in @('config.env', 'labels.tsv', 'assignees.tsv', 'team-modes.tsv')) { Copy-Item (Join-Path $Root "templates\.ai-core\$f") (Join-Path $dir $f) }
  & git -C $dir init -q
  & git -C $dir add -A
  $name = if ($env:GIT_AUTHOR_NAME) { $env:GIT_AUTHOR_NAME } else { 'ai-core' }
  $mail = if ($env:GIT_AUTHOR_EMAIL) { $env:GIT_AUTHOR_EMAIL } else { 'ai-core@localhost' }
  & git -C $dir -c "user.name=$name" -c "user.email=$mail" commit -q -m 'the project harness, from the skeleton of setup-ai-core'
  & gh repo create $Full --private --source $dir --push 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Remove-Item -Recurse -Force $dir
    throw "could not create $Full on GitHub (no permission, or gh is not logged in)"
  }
  Write-Host "created: $Full, private, from the skeleton, at $dir"
  return $dir
}

function Get-LayerExtends {
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Dir)
  $f = Join-Path $Dir 'ai-core.json'
  if (-not (Test-Path $f)) { return $null }
  $j = Get-Content $f -Raw | ConvertFrom-Json
  if ($j.PSObject.Properties['extends'] -and $j.extends) { return [string]$j.extends }
  return $null
}

function Get-LayerRequires {
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Dir)
  $f = Join-Path $Dir 'ai-core.json'
  if (-not (Test-Path $f)) { return $null }
  $j = Get-Content $f -Raw | ConvertFrom-Json
  if ($j.PSObject.Properties['setup-ai-core'] -and $j.'setup-ai-core') { return [string]$j.'setup-ai-core' }
  return $null
}

function Test-VersionAtLeast {
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Have, [Parameter(Mandatory)][string]$Want)
  $h = @(($Have -split '\.') + @('0', '0', '0') | Select-Object -First 3 | ForEach-Object { [int]$_ })
  $w = @(($Want -split '\.') + @('0', '0', '0') | Select-Object -First 3 | ForEach-Object { [int]$_ })
  for ($i = 0; $i -lt 3; $i++) { if ($h[$i] -gt $w[$i]) { return $true }; if ($h[$i] -lt $w[$i]) { return $false } }
  return $true
}

function Resolve-LayerChain {
  # Every layer from the base down to the named one, cloned or pulled on the way, as directories;
  # -Dry moves, clones and creates nothing
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Full, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Folder, [switch]$Create, [switch]$Dry)
  $version = (Get-Content (Join-Path $Root 'VERSION') -Raw).Trim()
  $chain = @(); $seen = @(); $n = 0; $create = [bool]$Create; $start = $Full
  while ($Full) {
    $n++; if ($n -gt 8) { throw "the extends chain of $start is longer than eight" }
    if ($seen -ccontains $Full) { throw "the extends chain of $start runs in a circle at $Full" }
    $seen += $Full
    $dir = Resolve-Layer -Full $Full -Root $Root -Folder $Folder -Create:$create -Dry:$Dry
    $create = $false
    if (Test-Path $dir) {
      $req = Get-LayerRequires $dir
      if ($req -and $req.StartsWith('>=', [StringComparison]::Ordinal)) {
        if (-not (Test-VersionAtLeast $version $req.Substring(2))) { throw "$Full needs setup-ai-core $req and this clone is ${version}; run ai-core update" }
      }
    }
    $chain = @($dir) + $chain
    $Full = if (Test-Path $dir) { Get-LayerExtends $dir } else { $null }
  }
  return $chain
}

Export-ModuleMember -Function Get-OriginParts, Get-HarnessOf, Get-ProjectFolderOf, Get-LayerDir, Resolve-Layer, Get-LayerExtends, Get-LayerRequires, Test-VersionAtLeast, Resolve-LayerChain
