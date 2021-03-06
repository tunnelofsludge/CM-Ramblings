﻿function Get-PendingSCCMReboot {
    [OutputType([boolean])]
    param
    (
        [parameter(Mandatory = $false)]
        [string]$ComputerName = $env:COMPUTERNAME,
        [parameter(Mandatory = $false)]
        [pscredential]$Credential
    )
    try {
        $ReturnValue = $false
        $WMIQuery = $false
        $EvalStateQuery = $false
        $invokeWmiMethodSplat = @{
            Name         = 'DetermineIfRebootPending'
            ComputerName = $ComputerName
            Namespace    = 'root\ccm\clientsdk'
            Class        = 'CCM_ClientUtilities'
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $invokeWmiMethodSplat.Add('Credential', $Credential)
        }
        $PendingReboot = Invoke-WmiMethod @invokeWmiMethodSplat
        if (($null -ne $PendingReboot) -and $PendingReboot.RebootPending) {
            $WMIQuery = $true
        }
        $getWmiObjectSplat = @{
            ComputerName = $ComputerName
            Namespace    = 'root\CCM\ClientSDK'
            Class        = 'CCM_SoftwareUpdate'
            Filter       = "NOT Name LIKE '%Definition%'"
        }
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $getWmiObjectSplat.Add('Credential', $Credential)
        }
        $CurrentStatus = Get-WmiObject @getWmiObjectSplat
        if ($CurrentStatus.EvaluationState -contains '8') {
            $EvalStateQuery = $true
        }
    }
    catch {
    }
    if ($EvalStateQuery -or $WMIQuery) {
        $ReturnValue = $true
    }
    return $ReturnValue
}
