<#
.SYNOPSIS
Add one option to a single-select field of a board - a status column, a priority.

.EXAMPLE
./field-option-add.ps1 -Field Priority -Name P9 -Color GRAY
./field-option-add.ps1 -Project 6 -Field Priority -Name P9 -Color GRAY -Description 'Parked: kept rather than closed'

.NOTES
Running it twice changes nothing the second time: an option the field already has is
reported and nothing is sent.

WHY THIS IS A SCRIPT AND NOT A LINE SOMEBODY TYPES ONCE. The mutation behind it,
updateProjectV2Field, does not ADD an option - it REPLACES the whole list with what it is
given. An option left out of that list is DELETED, and with it the value goes off every
card that carried it. So the field is read first and its current options are sent back
beside the new one, and that read-then-write is the part nobody should retype from memory
at midnight.

AN EXISTING OPTION IS SENT BACK WITH ITS id, AND THAT IS THE WHOLE OF IT. The input type
carries an OPTIONAL id: with it, GitHub updates the option that already exists; without
it, GitHub creates a NEW one - so a list of the same names, the same colours and the same
descriptions, sent without ids, replaces every option with a fresh one and CLEARS the field
on every card that carried a value. Measured on 2026-08-26: adding P9 to both boards this
way emptied the Priority column of 18 cards, and nothing in the answer said so - the
mutation reported the five option names it was asked for.

WHAT IT CANNOT GUARANTEE: the read and the write are two calls
and GitHub offers no way to make them one. An option somebody else adds between them is
not in the list this run sends, so it is deleted. The window is one round trip and there
is no way to close it from here.

The colour is one of GitHub's own option colours. It is required - a colour defaulted here
would make every option added by this script look alike whether or not that was meant.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string] $Field,
  [Parameter(Mandatory)][string] $Name,
  [Parameter(Mandatory)][ValidateSet('GRAY','BLUE','GREEN','YELLOW','ORANGE','RED','PINK','PURPLE', IgnoreCase=$false)][string] $Color,
  [string] $Description = '',
  [string] $Project = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Board.psm1') -Force

Set-Project -Number $Project | Out-Null

# Read whole, then decided on. gh's own --jq is not used here because the SAME answer is
# read twice below - once for the field id and once for the options it already carries.
$q = 'query($pid:ID!) { node(id:$pid) { ... on ProjectV2 { fields(first:50) { nodes { ... on ProjectV2SingleSelectField { id name options { id name color description } } } } } } }'
$fields = (Invoke-Gh api graphql -f "pid=$(Get-ProjectId)" -f "query=$q" | ConvertFrom-Json).data.node.fields.nodes |
            Where-Object { $_.name }

$hit = $fields | Where-Object { $_.name -ceq $Field } | Select-Object -First 1
if (-not $hit) {
  Stop-WithError "no single-select field named '$Field' on board $(Get-ProjectNumber). There is: $(($fields.name) -join ' ')"
}

if ($hit.options.name -ccontains $Name) {
  "board $(Get-ProjectNumber): field '$Field' already has '$Name' - nothing sent"
  exit 0
}

# THE REQUEST BODY IS BUILT AS OBJECTS AND CONVERTED, NOT GLUED TOGETHER AS TEXT. A
# description holding a double quote or a backslash written into the text of a JSON
# document is not data any more, and the option list carries descriptions somebody typed
# on a web page.
#
# `description` comes back null for an option that has none, and the input type takes a
# String and not a null, so an absent one is sent as empty.
$opts = @($hit.options | ForEach-Object {
  [ordered]@{ id = $_.id; name = $_.name; color = $_.color; description = $(if ($_.description) { $_.description } else { '' }) }
})
# The new option carries NO id, which is what tells GitHub to create it.
$opts += [ordered]@{ name = $Name; color = $Color; description = $Description }

$m = 'mutation($fid:ID!, $opts:[ProjectV2SingleSelectFieldOptionInput!]!) {
        updateProjectV2Field(input:{fieldId:$fid, singleSelectOptions:$opts}) {
          projectV2Field { ... on ProjectV2SingleSelectField { options { id name } } } } }'
$body = [ordered]@{ query = $m; variables = [ordered]@{ fid = $hit.id; opts = $opts } }

$file = [IO.Path]::GetTempFileName()
try {
  Set-Content -Path $file -Value ($body | ConvertTo-Json -Depth 8) -Encoding utf8
  $after = Invoke-Gh api graphql --input $file --jq '.data.updateProjectV2Field.projectV2Field.options[].name'
}
finally { Remove-Item $file -Force -EA SilentlyContinue }

# The board's field cache holds the option set as it was BEFORE this run. Left standing,
# every later script resolves names against a list that no longer matches the board, and
# the name just added is the one it cannot find.
Remove-Item (Join-Path (Get-CacheDir) 'fields.tsv') -Force -EA SilentlyContinue

"board $(Get-ProjectNumber): field '$Field' now has $(@($after) -join ' ')"
