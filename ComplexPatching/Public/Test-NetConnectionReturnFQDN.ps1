﻿function Test-NetConnectionReturnFQDN {
    param
    (
        [parameter(Mandatory = $true)]
        [string]$ComputerName,
        # Provides the name of the server we are checking connectivity to

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
    $ScriptName = $((Split-Path $PSCommandPath -Leaf) -Replace '.ps1', $null)

    #region set our defaults for the our functions
    #region Write-CMLogEntry defaults
    $Bias = Get-WmiObject -Class Win32_TimeZone | Select-Object -ExpandProperty Bias
    $PSDefaultParameterValues.Add("Write-CMLogEntry:Bias", $Bias)
    $PSDefaultParameterValues.Add("Write-CMLogEntry:FileName", [string]::Format("{0}-{1}.log", $RBInstance, $ComputerName))
    $PSDefaultParameterValues.Add("Write-CMLogEntry:Folder", $LogLocation)
    $PSDefaultParameterValues.Add("Write-CMLogEntry:Component", "[$ComputerName]::[$ScriptName]")
    #endregion Write-CMLogEntry defaults

    #region Update-DBServerStatus defaults
    $PSDefaultParameterValues.Add("Update-DBServerStatus:ComputerName", $ComputerName)
    $PSDefaultParameterValues.Add("Update-DBServerStatus:RBInstance", $RBInstance)
    $PSDefaultParameterValues.Add("Update-DBServerStatus:SQLServer", $SQLServer)
    $PSDefaultParameterValues.Add("Update-DBServerStatus:Database", $OrchStagingDB)
    #endregion Update-DBServerStatus defaults

    #region Start-CompPatchQuery defaults
    $PSDefaultParameterValues.Add("Start-CompPatchQuery:SQLServer", $SQLServer)
    $PSDefaultParameterValues.Add("Start-CompPatchQuery:Database", $OrchStagingDB)
    #endregion Start-CompPatchQuery defaults
    #endregion set our defaults for our functions

    Write-CMLogEntry "Runbook activity script started - [Running On = $env:ComputerName]"
    Update-DBServerStatus -Status "Started $ScriptName" -SetRBInstance
    Update-DBServerStatus -Stage 'Start' -Component $ScriptName -DryRun $DryRun

    $global:CurrentAction = ""
    $FQDN = $null

    $FQDN_FromDB = Get-FQDNFromDB -ComputerName $ComputerName -SQLServer $SQLServer -Database $OrchStagingDB

    try {
        Write-CMLogEntry "Performing Test-NetConnection on $ComputerName to determine if it is on"

        if (Test-NetConnection -ComputerName $FQDN_FromDB -InformationLevel Quiet) {
            Write-CMLogEntry "Test-NetConnection to $ComputerName was successful, now attempt to resolve FQDN"
            try {
                $FQDN = ([System.Net.DNS]::GetHostEntry($FQDN_FromDB)).Hostname
                $FoundFQDN = $true
            }
            catch {
                $FoundFQDN = $false
            }
            if ($FoundFQDN) {
                Write-CMLogEntry "FQDN is $FQDN"
                Update-DBServerStatus -Status 'Started' -LastStatus 'Verified Powered On'
                $ResultStatus = "Success"
            }
            else {
                Write-CMLogEntry "Failed to resolve the FQDN of $ComputerName" -Severity 3
                Update-DBServerStatus -Status 'Failed' -LastStatus 'Get FQDN Failed'
                $ResultStatus = "Failed"
            }
        }
        else {
            Write-CMLogEntry "Failed to establish a connection to $ComputerName" -Severity 3
            Update-DBServerStatus -Status 'Failed' -LastStatus 'Ping Failed'
            $ResultStatus = "Failed"
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
            Write-CMLogEntry "Exiting script with result [$ResultStatus] and error message [$ErrorMessage]" -Severity 3
        }
        else {
            Write-CMLogEntry "Exiting script with result [$ResultStatus]"
        }

    }

    # Record end of activity script process
    Update-DBServerStatus -Status "Finished $ScriptName"
    Update-DBServerStatus -Stage 'End' -Component $ScriptName
    Write-CMLogEntry "Script finished"
}