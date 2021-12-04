$ErrorActionPreference = 'Stop' # Stop immediately on error, this will not lead into unwated comments.

if ($env:SCOOP_BRANCH) {
    Push-Location $env:SCOOP_HOME
    git checkout $env:SCOOP_BRANCH
    Pop-Location
}

# Import all modules
Join-Path $PSScriptRoot 'src' | Get-ChildItem -File | Select-Object -ExpandProperty Fullname | Import-Module

# TODO: Move to top
$VerbosePreference = 'Continue' # Preserve verbose in logs

Test-NestedBucket
Initialize-NeededSettings

Write-Log 'Importing all modules'
# Load all scoop's modules.
# Dot sourcing needs to be done on highest scope possible to propagate into lower scopes
Get-ChildItem (Join-Path $env:SCOOP_HOME 'lib') '*.ps1' | ForEach-Object { . $_.FullName }
# Same for function recreating. Needs to be done after import and on highest scope
Initialize-MockedFunctionsFromCore

Write-Log 'FULL EVENT' $EVENT_RAW

Invoke-Action

if ($env:NON_ZERO_EXIT) { exit $NON_ZERO }
