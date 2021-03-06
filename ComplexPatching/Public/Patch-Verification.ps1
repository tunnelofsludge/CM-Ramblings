﻿function Patch-Verification {
    param
    (
        [parameter(Mandatory = $true)]
        [string]$ComputerName,
        # Provides the computer name to verify patches on

        [parameter(Mandatory = $true)]
        [string]$DryRun,
        # skips patching check so that we can perform a dry run of the drain an resume

        [parameter(Mandatory = $true)]
        [int32]$RBInstance,
        # RBInstance which represents the Runbook Process ID for this runbook workflow

        [parameter(Mandatory = $true)]
        [string]$SQLServer,
        # Database server for staging information during the patching process

        [parameter(Mandatory = $true)]
        [string]$OrchStagingDB,
        # Database for staging information during the patching process

        [parameter(Mandatory = $true)]
        [string]$LogLocation
        # UNC path to store log files in
    )

    #region import modules
    Import-Module -Name ComplexPatching
    #endregion import modules

    #-----------------------------------------------------------------------

    ## Initialize result and trace variables
    # $ResultStatus provides basic success/failed indicator
    # $ErrorMessage captures any error text generated by script
    # $Trace is used to record a running log of actions
    [bool]$DryRun = ConvertTo-Boolean $DryRun
    $ResultStatus = ""
    $ErrorMessage = ""
    $global:CurrentAction = ""
    $Patched = $false
    $Done = $false
    $ScriptName = $((Split-Path $PSCommandPath -Leaf) -Replace '.ps1', $null)

    #region set our defaults for the our functions
    #region Start-CompPatchQuery defaults
    $PSDefaultParameterValues.Add("Start-CompPatchQuery:SQLServer", $SQLServer)
    $PSDefaultParameterValues.Add("Start-CompPatchQuery:Database", $OrchStagingDB)
    #endregion Start-CompPatchQuery defaults

    #region create credential objects
    $RemotingCreds = Get-StoredCredential -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB
    #endregion create credential objects

    #region Write-CMLogEntry defaults
    $Bias = Get-WmiObject -Class Win32_TimeZone | Select-Object -ExpandProperty Bias
    $PSDefaultParameterValues.Add("Write-CMLogEntry:Bias", $Bias)
    $PSDefaultParameterValues.Add("Write-CMLogEntry:FileName", [string]::Format("{0}-{1}.log", $RBInstance, $ComputerName))
    $PSDefaultParameterValues.Add("Write-CMLogEntry:Folder", $LogLocation)
    $PSDefaultParameterValues.Add("Write-CMLogEntry:Component", "[$ComputerName]::[$ScriptName]")
    #endregion Write-CMLogEntry defaults

    #region Start-CMClientAction defaults
    $PSDefaultParameterValues.Add("Start-CMClientAction:Credential", $RemotingCreds)
    $PSDefaultParameterValues.Add("Start-CMClientAction:SQLServer", $SQLServer)
    $PSDefaultParameterValues.Add("Start-CMClientAction:Database", $OrchStagingDB)
    $PSDefaultParameterValues.Add("Start-CMClientAction:FileName", [string]::Format("{0}-{1}.log", $RBInstance, $ComputerName))
    $PSDefaultParameterValues.Add("Start-CMClientAction:Folder", $LogLocation)
    $PSDefaultParameterValues.Add("Start-CMClientAction:Component", "[$ComputerName]::[$ScriptName]")
    #endregion Start-CMClientAction defaults

    #region Get-UpdateFromDB defaults
    $PSDefaultParameterValues.Add("Get-UpdateFromDB:ComputerName", $ComputerName)
    $PSDefaultParameterValues.Add("Get-UpdateFromDB:RBInstance", $RBInstance)
    $PSDefaultParameterValues.Add("Get-UpdateFromDB:SQLServer", $SQLServer)
    $PSDefaultParameterValues.Add("Get-UpdateFromDB:Database", $OrchStagingDB)
    #endregion Get-UpdateFromDB defaults

    #region Set-UpdateInDB defaults
    $PSDefaultParameterValues.Add("Set-UpdateInDB:ComputerName", $ComputerName)
    $PSDefaultParameterValues.Add("Set-UpdateInDB:RBInstance", $RBInstance)
    $PSDefaultParameterValues.Add("Set-UpdateInDB:SQLServer", $SQLServer)
    $PSDefaultParameterValues.Add("Set-UpdateInDB:Database", $OrchStagingDB)
    $PSDefaultParameterValues.Add("Set-UpdateInDB:FileName", [string]::Format("{0}-{1}.log", $RBInstance, $ComputerName))
    $PSDefaultParameterValues.Add("Set-UpdateInDB:Folder", $LogLocation)
    $PSDefaultParameterValues.Add("Set-UpdateInDB:Component", "[$ComputerName]::[$ScriptName]")
    #endregion Set-UpdateInDB defaults

    #region Update-DBServerStatus defaults
    $PSDefaultParameterValues.Add("Update-DBServerStatus:ComputerName", $ComputerName)
    $PSDefaultParameterValues.Add("Update-DBServerStatus:RBInstance", $RBInstance)
    $PSDefaultParameterValues.Add("Update-DBServerStatus:SQLServer", $SQLServer)
    $PSDefaultParameterValues.Add("Update-DBServerStatus:Database", $OrchStagingDB)
    #endregion Update-DBServerStatus defaults
    #endregion set our defaults for our functions


    Write-CMLogEntry "Runbook activity script started - [Running On = $env:ComputerName]"
    Update-DBServerStatus -Status "Started $ScriptName"
    Update-DBServerStatus -Stage 'Start' -Component $ScriptName -DryRun $DryRun

    try {
        $FQDN = Get-FQDNFromDB -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB
        $WillPatchQuery = [string]::Format("SELECT Patch FROM [dbo].[ServerStatus] WHERE ServerName='{0}'", $ComputerName)
        $Patch = Start-CompPatchQuery -Query $WillPatchQuery | Select-Object -ExpandProperty Patch
        if ($Patch -and -not $DryRun) {
            #region initiate CIMSession, looping until one is made, or it has been 10 minutes
            Update-DBServerStatus -LastStatus 'Creating CIMSession'
            Write-CMLogEntry 'Creating CIMSession'
            New-LoopAction -LoopTimeout 10 -LoopTimeoutType Minutes -LoopDelay 10 -ExitCondition { $script:CIMSession } -ScriptBlock {
                $script:CIMSession = New-MrCimSession -Credential $script:RemotingCreds -ComputerName $script:FQDN
            } -IfSucceedScript {
                Update-DBServerStatus -LastStatus "CIMSession Created"
                Write-CMLogEntry 'CIMSession created succesfully'
            } -IfTimeoutScript {
                Write-CMLogEntry 'Failed to create CIMSession'
                throw 'Failed to create CIMsession'
            }
            #endregion initiate CIMSession, looping until one is made, or it has been 10 minutes

            #region Get status of all updates logged to SQL DB (ArticleID,AssignmentID,ComplianceState,EvaluationState)
            Write-CMLogEntry "Checking DB for all updates associated with $ComputerName that are not currently marked as installed"
            $NotMarkedInstalledQuery = [string]::Format("SELECT ArticleID,AssignmentID,ComplianceState,EvaluationState,LastAction FROM [dbo].[SoftwareUpdates] WHERE ServerName='{0}' AND EvaluationState != '12'", $script:ComputerName)
            $UpdatesNotMarkedInstalled = Start-CompPatchQuery -Query $NotMarkedInstalledQuery
            $NotInstalledCount = ($UpdatesNotMarkedInstalled | Measure-Object).count
            Write-CMLogEntry "Identified $NotInstalledCount updates marked as not installed in the database."
            #endregion Get status of all updates logged to SQL DB (ArticleID,AssignmentID,ComplianceState,EvaluationState)

            if (($UpdatesNotMarkedInstalled | Select-Object -ExpandProperty EvaluationState -Unique) -ne '13') {
                Update-DBServerStatus -LastStatus "Verifying Patches"

                #region Looped patch verification
                $newLoopActionSplat = @{
                    ExitCondition   = { $script:Done }
                    IfTimeoutScript = {
                        Write-CMLogEntry -Value "Failed to verify patches after 10 minutes. Will mark as not patched and attempt to re-patch" -Severity 2
                        $script:Patched = $false
                        $script:Done = $false
                    }
                    ScriptBlock     = {
                        Start-CMClientAction -Schedule UpdateScan, UpdateEval -ComputerName $FQDN
                            
                        $NotMarkedInstalledQuery = [string]::Format("SELECT ArticleID,AssignmentID,ComplianceState,EvaluationState,LastAction FROM [dbo].[SoftwareUpdates] WHERE ServerName='{0}' AND EvaluationState != '12'", $script:ComputerName)
                        $UpdatesNotMarkedInstalled = Start-CompPatchQuery -Query $NotMarkedInstalledQuery
                        $NotInstalledCount = ($UpdatesNotMarkedInstalled | Measure-Object).count
                        if ($NotInstalledCount -ne 0) {
                            #region check if the AssignmentID is marked as compliant
                            $AssignmentIDs = (($UpdatesNotMarkedInstalled.AssignmentID -join ';') -replace ';;', ';') -split ';' | Where-Object { $_ } | Select-Object -Unique
                            $Compliance = New-Object System.Collections.ArrayList
                            foreach ($ID in $AssignmentIDs) {
                                Remove-Variable Result
                                $Result = Get-CimInstance -ClassName CCM_AssignmentCompliance -Namespace ROOT\ccm\SoftwareUpdates\DeploymentAgent -Filter "AssignmentID = '$ID'" -CimSession $script:CIMSession -OperationTimeoutSec 3 | Select-Object -ExpandProperty IsCompliant
                                if (-not $Result) {
                                    $Result = $false
                                }
                                $Compliance.Add($Result) | Out-Null
                                Write-CMLogEntry "Identified [AssignmentID=$ID] [Compliance=$Result]"
                            }
                            if ($Compliance -notcontains $false -and $Compliance -contains $true) {
                                Write-CMLogEntry "[AssignmentID]::Identified that all AssignmentIDs are marked compliant, marking update compliance in the DB"
                                Update-DBServerStatus -LastStatus 'Patches Verified'
                                $MarkAllInstalledQuery = [string]::Format("UPDATE [dbo].[SoftwareUpdates] SET ComplianceState = 1, EvaluationState = 12, LastAction = 'Verified' WHERE ServerName='{0}'", $script:ComputerName)
                                Start-CompPatchQuery -Query $MarkAllInstalledQuery
                                $script:Patched = $true
                                $script:Done = $true
                            }
                            #endregion check if the AssignmentID is marked as compliant
            
                            #region check QFE,UpdatesStore,DeploymentAgent
                            $CCMUS = Get-CimInstance -ClassName CCM_UpdateStatus -Namespace ROOT\ccm\SoftwareUpdates\UpdatesStore -CimSession $script:CIMSession -OperationTimeoutSec 15
                            $CCMTU = Get-CimInstance -ClassName CCM_TargetedUpdateEx1 -Namespace ROOT\ccm\SoftwareUpdates\DeploymentAgent -CimSession $script:CIMSession -OperationTimeoutSec 15
                            foreach ($Update in $UpdatesNotMarkedInstalled) {
                                Write-CMLogEntry "Found [ArticleID=KB$($Update.ArticleID)] [LastAction=$($Update.LastAction)] in database"
                                $Installed = $false
                                $FullHotfixID = 'KB' + $Update.ArticleID
                                $Installed = Get-CimInstance -ClassName Win32_QuickFixEngineering -Filter "HotFixID = '$FullHotfixID'" -OperationTimeoutSec 3 -CimSession $script:CIMSession
                                if ($Installed) {
                                    Write-CMLogEntry "[QFE]::Identified that KB$($Update.ArticleID) is installed, marking update compliance in the DB"
                                    Set-UpdateInDB -Action Update -ArticleID $($Update.ArticleID) -ComplianceState 1 -EvaluationState 12 -LastAction 'Verified'
                                }
                                else {
                                    Write-CMLogEntry "Unable to find KB$($Update.ArticleID) on $script:ComputerName via the QFE class in WMI, now checking CCM_UpdateStatus"
                                    $Installed = $CCMUS | Where-Object { $_.article -eq "$($Update.ArticleID)" }
                                    if ($Installed.Status -contains "Installed") {
                                        $InstalledCount = $Installed | Where-Object { $_.Status -eq "Installed" } | Measure-Object | Select-Object -ExpandProperty Count
                                        if ($InstalledCount -eq $Installed.Count) {
                                            Write-CMLogEntry "[CCMUS]::Identified that KB$($Update.ArticleID) is installed, marking update compliance in the DB"
                                            Set-UpdateInDB -Action Update -ArticleID $($Update.ArticleID) -ComplianceState 1 -EvaluationState 12 -LastAction 'Verified'
                                        }
                                        else {
                                            foreach ($UniqueID in $Installed.UniqueID) {
                                                $Installed = $CCMTU.where{ $_.UpdateID -match $UniqueID }
                                                if ($Installed.UpdateStatus -eq '12') {
                                                    Write-CMLogEntry "[CCMTU]::Identified that KB$($Update.ArticleID) is installed, marking update compliance in the DB"
                                                    Set-UpdateInDB -Action Update -ArticleID $($Update.ArticleID) -ComplianceState 1 -EvaluationState 12 -LastAction 'Verified'
                                                }
                                            }
                                        }
                                    }
                                    else {
                                        Write-CMLogEntry "Unable to find KB$($Update.ArticleID) on $script:ComputerName via the CCM_UpdateStatus."
                                    }
                                }
                            }
                            #endregion check QFE,UpdatesStore,DeploymentAgent
            
                            #region check how many updates aren't marked installed
                            $NotMarkedInstalledQuery = [string]::Format("SELECT ArticleID,AssignmentID,ComplianceState,EvaluationState,LastAction FROM [dbo].[SoftwareUpdates] WHERE ServerName='{0}' AND EvaluationState != '12'", $script:ComputerName)
                            $UpdatesNotMarkedInstalled = Start-CompPatchQuery -Query $NotMarkedInstalledQuery
                            $NotInstalledCount = $UpdatesNotMarkedInstalled | Measure-Object | Select-Object -ExpandProperty Count
                            if ($NotInstalledCount -eq 0) {
                                Write-CMLogEntry "Found that all updates in DB for $script:ComputerName are already marked as installed"
                                Update-DBServerStatus -LastStatus 'Patches Verified'
                                $script:Patched = $true
                                $script:Done = $true
                            }
                            #endregion check how many updates aren't marked installed
                        }
                        else {
                            Write-CMLogEntry "Found that all updates in DB for $ComputerName are already marked as installed"
                            Update-DBServerStatus -LastStatus 'Patches Verified'
                            $script:Patched = $true
                            $script:Done = $true
                        }
                    }
                    LoopDelayType   = 'Seconds'
                    LoopDelay       = 15
                    LoopTimeoutType = 'Minutes'
                    LoopTimeout     = 10
                }
                New-LoopAction @newLoopActionSplat

                if ($Patched) {
                    Start-CMClientAction -Schedule UpdateScan, UpdateEval -ComputerName $FQDN
                    Start-Sleep -Seconds 60
                    Start-CMClientAction -Schedule UpdateScan, UpdateEval -ComputerName $FQDN
                    Start-Sleep -Seconds 60

                    #region Check for updates and insert into SQL appropriately
                    Write-CMLogEntry "Checking CCM_SoftwareUpdate for missing updates that are with a filter `"NOT Name LIKE '%Definition%' and ComplianceState=0`""
                    [System.Management.ManagementObject[]]$MissingUpdates = Get-WmiObject -Class CCM_SoftwareUpdate -Filter "NOT Name LIKE '%Definition%' and ComplianceState=0" -Namespace root\CCM\ClientSDK -ComputerName $ComputerName -Credential $RemotingCreds -ErrorAction Stop
                    if ($MissingUpdates -is [Object]) {
                        $Patched = $false
                        $PatchCount = $MissingUpdates.Count
                        Write-CMLogEntry "Found $PatchCount for $ComputerName"
                        Foreach ($Update in $MissingUpdates) {
                            if (($Update.ComplianceState -match "^0$|^2$") -and ($Update.EvaluationState -match "^0$|^1$|^13$")) {
                                if (Get-UpdateFromDB -ArticleID $Update.ArticleID) {
                                    Set-UpdateInDB -Action Update -ArticleID $Update.ArticleID -ComplianceState $Update.ComplianceState -EvaluationState $Update.EvaluationState
                                }
                                else {
                                    $AssignmentID = Get-CimInstance -CimSession $CIMSession -Classname CCM_TargetedUpdateEx1 -Namespace Root\ccm\softwareupdates\deploymentagent -Filter "UpdateId = '$($Update.UpdateID)'" | Select-Object -ExpandProperty RefAssignments -Unique
                                    Set-UpdateInDB -Action Insert -ArticleID $Update.ArticleID -ComplianceState $Update.ComplianceState -EvaluationState $Update.EvaluationState -AssignmentID $AssignmentID
                                }
                            }
                        }
                    }
                    else {
                        $Patched = $true
                    }
                    #endregion Check for updates and insert into SQL appropriately

                }
            }
            else {
                Write-CMLogEntry -Value "Identified that all patches for $ComputerName are in an error state. Patch verification will be skipped" -Severity 2
            }

            #endregion Looped patch verification
        }
        else {
            if (-not $Patch) {
                Write-CMLogEntry -Value "Server identifed in DB as exception to patching. Will skip patching verification" -Severity 2
            }
            if ($DryRun) {
                Write-CMLogEntry -Value "Performing DryRun. Will skip patching verification" -Severity 2
            }
            $ResultStatus = 'Success'
            $Patched = $true
            $Done = $true
        }
    }
    catch {
        # Catch any errors thrown above here, setting the result status and recording the error message to return to the activity for data bus publishing
        $ResultStatus = "Failed"
        $ErrorMessage = $error[0].Exception.Message
        Write-CMLogEntry "Exception caught during action [$global:CurrentAction]: $ErrorMessage" -Severity 3
    }
    finally {
        # Always do whatever is in the finally block. In this case, adding some additional detail about the outcome to the trace log for return
        if ($ErrorMessage.Length -gt 0) {
            Write-CMLogEntry "Exiting script with result [$ResultStatus] AND error message [$ErrorMessage]" -Severity 3
        }
        else {
            Write-CMLogEntry "Exiting script with result [Patched=$Patched]"
        }
        if ($CIMSession) {
            $CIMSession.Close()
        }
    }

    # Record end of activity script process
    Update-DBServerStatus -Status "Finished $ScriptName"
    Update-DBServerStatus -Stage 'End' -Component $ScriptName
    Write-CMLogEntry "Script finished"
}