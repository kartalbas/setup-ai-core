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

function Resolve-Layer {
  # The clone is there and current, or is moved from the home directory, or is cloned, or is
  # created from the skeleton with -Create; -Dry moves and creates nothing. Returns the clone
  # directory; throws when it cannot be had.
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Full, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Folder, [switch]$Create, [switch]$Dry)
  $dir = Get-LayerDir -Full $Full -Folder $Folder
  $old = Join-Path $HOME (".{0}" -f ($Full -split '/', 2)[1])
  if (-not (Test-Path (Join-Path $dir '.git')) -and (Test-Path (Join-Path $old '.git'))) {
    if ($Dry) { Write-Host "note: $Full would be moved from $old to $dir, beside the repositories it serves (dry run: not moved)"; $dir = $old }
    else { Move-Item -LiteralPath $old -Destination $dir; Write-Host "moved: $Full from $old to $dir, beside the repositories it serves" }
  }
  if (Test-Path (Join-Path $dir '.git')) {
    $origin = "$(& git -C $dir remote get-url origin 2>$null)".Trim()
    $o = $origin; if ($o.EndsWith('.git', [StringComparison]::Ordinal)) { $o = $o.Substring(0, $o.Length - 4) }
    if (-not ($o -cmatch ('github\.com[:/]' + [regex]::Escape($Full) + '$'))) { throw "$dir is a clone of $(if ($origin) { $origin } else { 'nothing' }), not of ${Full}; move it away" }
    & git -C $dir pull --ff-only --quiet 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "note: could not pull $Full into $dir (offline, or the clone has local changes); using it as it is" }
    return $dir
  }
  & gh repo view $Full --json name 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    if ($Dry) { return $dir }
    & gh repo clone $Full $dir -- --quiet 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not clone $Full to $dir" }
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
    throw "could not create $Full on GitHub (no permission, or gh is not logged in); the harness stays generic"
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
