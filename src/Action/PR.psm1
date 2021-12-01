Join-Path $PSScriptRoot '..\Helpers.psm1' | Import-Module

function Start-PR {
    <#
    .SYNOPSIS
        PR state handler.
    .OUTPUTS
        $null - Not supported state, which should be exited on.
        $true | $false
    #>
    $commented = $false

    switch ($EVENT.action) {
        'opened' {
            Write-Log 'Opened PR'
        }
        'created' {
            Write-Log 'Commented PR'

            if ($EVENT.comment.body -like '/verify*') {
                Write-Log 'Verify comment'

                if ($EVENT.issue.pull_request) {
                    Write-Log 'Pull request comment'

                    $commented = $true
                    # There is need to get actual pull request event
                    $content = Invoke-GithubRequest "repos/$REPOSITORY/pulls/$($EVENT.issue.number)" | Select-Object -ExpandProperty Content
                    $script:EVENT_new = ConvertFrom-Json $content
                } else {
                    Write-Log 'Issue comment'
                    $commented = $null # No need to do anything on issue comment
                }
            } else {
                Write-Log 'Not supported comment body'
                $commented = $null
            }
        }
        default {
            Write-Log 'Only action ''opened'' is supported'
            $commented = $null
        }
    }

    return $commented
}

function Set-RepositoryContext {
    <#
    .SYNOPSIS
        Repository context of commented PR is not set to correct $head.ref.
    #>
    param ([Parameter(Mandatory)] $Ref)

    # Alpine git do not have `git branch --show-current`
    # Replace current branch marked with asterisk to name only ('* master' -> 'master')
    if ((@(git branch) -replace '^\*\s+(.*)$', '$1') -ne $Ref) {
        Write-Log "Switching branch to $Ref"

        git pull
        git checkout $Ref
        git pull
    }
}

function New-FinalMessage {
    <#
    .SYNOPSIS
        Create and post final comment with information for collaborators.
    .PARAMETER Check
        Array of manifests checks.
    .PARAMETER Invalid
        Array of invalid manifests.
    #>
    param(
        [Object[]] $Check,
        [String[]] $Invalid
    )

    $prID = $EVENT.number
    $message = New-Array

    foreach ($ch in $Check) {
        Add-IntoArray $message "### $($ch.Name)"
        Add-IntoArray $message ''

        foreach ($status in $ch.Statuses.Keys) {
            $state = $ch.Statuses.Item($status)
            Write-Log $status $state
            # There is unsuccessful check
            if ($state -eq $false) { $env:NON_ZERO_EXIT = $true }
            Add-IntoArray $message (New-CheckListItem $status -OK:$state)
        }
        Add-IntoArray $message ''
    }

    if ($Invalid.Count -gt 0) {
        Write-Log 'PR contains invalid manifests'

        $env:NON_ZERO_EXIT = $true
        Add-IntoArray $message '### Invalid manifests'
        Add-IntoArray $message ''
        $Invalid | ForEach-Object { Add-IntoArray $message "- $_" }
    }

    # Add some more human friendly message
    if ($env:NON_ZERO_EXIT) {
        $message.Insert(0, '[Your changes do not pass checks.](https://github.com/Ash258/Scoop-GithubActions/wiki/Pull-Request-Checks)')
        Add-Label -ID $prID -Label 'package-fix-needed'
    } else {
        $message.InsertRange(0, @('All changes look good.', '', 'Wait for review from human collaborators.'))
        Remove-Label -ID $prID -Label 'package-fix-needed'
        Add-Label -ID $prID -Label 'review-needed'
    }

    # TODO: Comment URL to action log
    # $url = "https://github.com/$REPOSITORY/runs/$RUN_ID"
    # Add-IntoArray $message "_See log of all checks in <$url>_"

    Add-Comment -ID $prID -Message $message
}

function Test-PRFile {
    <#
    .SYNOPSIS
        Validate all changed files.
    .PARAMETER File
        Changed files in pull request.
    .OUTPUTS
        Tupple of check object and array of invalid manifests.
    #>
    param([Object[]] $File)

    $check = @()
    $invalid = @()
    foreach ($f in $File) {
        Write-Log "Starting $($f.filename) checks"

        # Reset variables from previous iteration
        $manifest = $null
        $object = $null
        $statuses = [Ordered] @{ }

        # Convert path into gci item to hold all needed information
        $manifest = Get-ChildItem $BUCKET_ROOT $f.filename
        Write-Log 'Manifest' $manifest

        # For Some reason -ErrorAction is not honored for convertfrom-json
        $old_e = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $object = Get-Content $manifest.Fullname -Raw | ConvertFrom-Json
        $ErrorActionPreference = $old_e

        if ($null -eq $object) {
            Write-Log 'Conversion failed'

            # Handling of configuration files (vscode, ...) will not be problem as soon as nested bucket folder is restricted
            Write-Log 'Extension' $manifest.Extension

            if ($manifest.Extension -eq '.json') {
                Write-Log 'Invalid JSON'
                $invalid += $manifest.Basename
            } else {
                Write-Log 'Not manifest at all'
            }
            Write-Log "Skipped $($f.filename)"
            continue
        }

        #region Property checks
        $statuses.Add('Description', ([bool] $object.description))
        $statuses.Add('License', ([bool] $object.license))
        # TODO: More advanced license checks
        #endregion Property checks

        #region Hashes
        if ($object.version -ne 'nightly') {
            Write-Log 'Hashes'
            $outputH = @(& (Join-Path $BINARIES_FOLDER 'checkhashes.ps1') -App $manifest.Basename -Dir $MANIFESTS_LOCATION *>&1)
            Write-Log 'Output' $outputH

            # everything should be all right when latest string in array will be OK
            $statuses.Add('Hashes', ($outputH[-1] -like 'OK'))

            Write-Log 'Hashes done'
        }
        #endregion Hashes

        #region Checkver
        if ($object.checkver) {
            Write-Log 'Checkver'
            $outputV = @(& (Join-Path $BINARIES_FOLDER 'checkver.ps1') -App $manifest.Basename -Dir $MANIFESTS_LOCATION -Force *>&1)
            Write-log 'Output' $outputV

            # If there are more than 2 lines and second line is not version, there is problem
            $checkver = ((($outputV.Count -ge 2) -and ($outputV[1] -like "$($object.version)")))
            $statuses.Add('Checkver', $checkver)

            #region Autoupdate
            if ($object.autoupdate) {
                switch -Wildcard ($outputV[-1]) {
                    'ERROR*' {
                        Write-Log 'Error in checkver'
                        $autoupdate = $false
                    }
                    "couldn't match*" {
                        Write-Log 'Version match fail'
                        $autoupdate = $false
                    }
                    'Writing updated*' {
                        Write-Log 'Autoupdate finished successfully'
                        $autoupdate = $true
                    }
                    default { $autoupdate = $checkver }
                }
                $statuses.Add('Autoupdate', $autoupdate)

                # There is some hash property defined in autoupdate
                if ($autoupdate -and ((hash $object.autoupdate '32bit') -or (hash $object.autoupdate '64bit'))) {
                    # If any item contains 'Could not find hash*' there is hash extraction error.
                    $statuses.Add('Autoupdate Hash Extraction', (($outputV -like 'Could not find hash*').Count -eq 0))
                }
            }
            #endregion Autoupdate

            Write-Log 'Checkver done'
        }
        #endregion Checkver

        #region formatjson
        # Write-Log 'Format'
        # TODO: implement format check using array compare if possible (or just strings with raws)
        # TODO: I am not sure if this will handle tabs and everything what could go wrong.
        #$raw = Get-Content $manifest.Fullname -Raw
        #$new_raw = $object | ConvertToPrettyJson
        #$statuses.Add('Format', ($raw -eq $new_raw))
        # Write-Log 'Format done'
        #endregion formatjson

        $check += [Ordered] @{ 'Name' = $manifest.Basename; 'Statuses' = $statuses }

        Write-Log "Finished $($f.filename) checks"
    }

    return $check, $invalid
}

function Initialize-PR {
    <#
    .SYNOPSIS
        Handle pull requests action.
    .DESCRIPTION
        1. Clone repository / Switch to correct branch
        2. Validate all changed manifests
        3. Post comment with check results
    #>
    Write-Log 'PR initialized'

    #region Stage 1 - Repository initialization
    $commented = Start-PR
    if ($null -eq $commented) { return } # Exit on not supported state
    Write-Log 'Commented?' $commented

    $EVENT | ConvertTo-Json -Depth 8 -Compress | Write-Log 'Pure PR Event'
    if ($EVENT_new) {
        Write-Log 'There is new event available'
        $EVENT = $EVENT_new
        $EVENT | ConvertTo-Json -Depth 8 -Compress | Write-Log 'New Event'
    }

    # TODO: Ternary
    $head = if ($commented) { $EVENT.head } else { $EVENT.pull_request.head }

    if ($head.repo.fork) {
        Write-Log 'Forked repository'

        # There is no need to run whole action under forked repository due to permission problem
        if ($commented -eq $false) {
            Write-Log 'Cannot comment with read only token'
            return
        }

        $REPOSITORY_forked = "$($head.repo.full_name):$($head.ref)"
        Write-Log 'Repo' $REPOSITORY_forked

        $cloneLocation = '/github/forked_workspace'
        git clone --branch $head.ref $head.repo.clone_url $cloneLocation
        $script:BUCKET_ROOT = $cloneLocation
        $buck = Join-Path $BUCKET_ROOT 'bucket'
        # TODO: Ternary
        $script:MANIFESTS_LOCATION = if (Test-Path $buck) { $buck } else { $BUCKET_ROOT }

        Write-Log "Switching to $REPOSITORY_forked"
        Push-Location $cloneLocation
    }

    # Repository context of commented PR is not set to $head.ref
    Set-RepositoryContext $head.ref
    #endregion Stage 1 - Repository initialization

    # In case of forked repository it needs to be '/github/forked_workspace'
    Get-Location | Write-Log 'Context of action'
    (Get-ChildItem $BUCKET_ROOT | Select-Object -ExpandProperty Basename) -join ', ' | Write-log 'Root Files'
    (Get-ChildItem $MANIFESTS_LOCATION | Select-Object -ExpandProperty Basename) -join ', ' | Write-log 'Manifests'

    # Do not run checks on removed files
    $files = Get-AllChangedFilesInPR $EVENT.number -Filter
    Write-Log 'PR Changed Files' $files

    # Stage 2 - Manifests validation
    $check, $invalid = Test-PRFile $files

    #region Stage 3 - Final Message
    Write-Log 'Checked manifests' $check.name
    Write-Log 'Invalids' $invalid

    if (($check.Count -eq 0) -and ($invalid.Count -eq 0)) {
        Write-Log 'No compatible files in PR'
        return
    }

    New-FinalMessage $check $invalid
    #endregion Stage 3 - Final Message

    Write-Log 'PR finished'
}

Export-ModuleMember -Function Initialize-PR
