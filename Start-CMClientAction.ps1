function Start-CMClientAction {
    <#
.SYNOPSIS
    Invokes CM Client actions on local or remote machines

.DESCRIPTION
    This script will allow you to invoke a set of CM Client actions on a machine (with optional credentials), providing a list of the actions and an optional delay betweens actions. 
    The function will attempt for a default of 5 minutes to invoke the action, with a 10 second delay inbetween attempts. This is to account for invoke-wmimethod failures.

.PARAMETER Schedule
	Define the schedules to run on the machine - 'HardwareInv', 'FullHardwareInv', 'SoftwareInv', 'UpdateScan', 'UpdateEval', 'MachinePol', 'AppEval', 'DDR'

.PARAMETER Delay
	Specify the delay in seconds between each schedule when more than one is ran - 0-30 seconds

.PARAMETER ComputerName
    Specifies the computers to run this against
    
.PARAMETER Timeout
    Specifies the timeout in minutes after which any individual computer will stop attempting the schedules. Default is 5 minutes.

.PARAMETER Credential
	Optional PSCredential

.EXAMPLE
	# Start a machine policy eval and a hardware inventory cycle
	Start-CMClientAction -Schedule MachinePol,HardwareInv

.NOTES
    FileName:    Start-CMClientAction.ps1
    Author:      Cody Mathis
    Contact:     @CodyMathis123
    Created:     11-29-2018
    Updated:     08-109-2019
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param
    (
        [parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true)]
        [Alias('Computer', 'HostName', 'ServerName', 'IPAddress')]
        [string[]]$ComputerName = $env:COMPUTERNAME,
        [parameter(Mandatory = $true)]
        [ValidateSet('HardwareInv', 'FullHardwareInv', 'SoftwareInv', 'UpdateScan', 'UpdateEval', 'MachinePol', 'AppEval', 'DDR')]
        [string[]]$Schedule,
        [parameter(Mandatory = $false)]
        [ValidateRange(0, 30)]
        [int]$Delay = 5,
        [parameter(Mandatory = $false)]
        [int]$Timeout = 5,
        [parameter(Mandatory = $false)]
        [pscredential]$Credential
    )
    begin {
        $TimeSpan = New-TimeSpan -Minutes $Timeout
    }
    process {
        foreach ($Computer in $ComputerName) {
            foreach ($Option in $Schedule) {
                $Action = switch -Regex ($Option) {
                    '^HardwareInv$|^FullHardwareInv$' {
                        '{00000000-0000-0000-0000-000000000001}'
                    }
                    '^SoftwareInv$' {
                        '{00000000-0000-0000-0000-000000000002}'
                    }
                    '^UpdateScan$' {
                        '{00000000-0000-0000-0000-000000000113}'
                    }
                    '^UpdateEval$' {
                        '{00000000-0000-0000-0000-000000000108}'
                    }
                    '^MachinePol$' {
                        '{00000000-0000-0000-0000-000000000021}'
                    }
                    '^AppEval$' {
                        '{00000000-0000-0000-0000-000000000121}'
                    }
                    '^DDR$' {
                        '{00000000-0000-0000-0000-000000000003}'
                    }
                }

                $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
                do {
                    try {
                        Remove-Variable MustExit -ErrorAction SilentlyContinue
                        Remove-Variable Invocation -ErrorAction SilentlyContinue
                        if ($Option -eq 'FullHardwareInv') {
                            $getWMIObjectSplat = @{
                                ComputerName = $Computer
                                Namespace    = 'root\ccm\invagt'
                                Class        = 'InventoryActionStatus'
                                Filter       = "InventoryActionID ='$Action'"
                                ErrorAction  = 'Stop'
                            }
                            if ($PSBoundParameters.ContainsKey('Credential')) {
                                $getWMIObjectSplat.Add('Credential', $Credential)
                            }
                            Write-Verbose "Attempting to delete Hardware Inventory history for $Computer as a FullHardwareInv was requested"
                            $HWInv = Get-WMIObject @getWMIObjectSplat
                            if ($null -ne $HWInv) {
                                $HWInv.Delete()
                                Write-Verbose "Hardware Inventory history deleted for $Computer"
                            }
                            else {
                                Write-Verbose "No Hardware Inventory history to delete for $Computer"
                            }
                        }
                        $invokeWmiMethodSplat = @{
                            ComputerName = $Computer
                            Name         = 'TriggerSchedule'
                            Namespace    = 'root\ccm'
                            Class        = 'sms_client'
                            ArgumentList = $Action
                            ErrorAction  = 'Stop'
                        }
                        if ($PSBoundParameters.ContainsKey('Credential')) {
                            $invokeWmiMethodSplat.Add('Credential', $Credential)
                        }
                        Write-Verbose "Triggering a $Option Cycle on $Computer via the 'TriggerSchedule' WMI method"
                        $Invocation = Invoke-WmiMethod @invokeWmiMethodSplat
                    }
                    catch [System.UnauthorizedAccessException] {
                        Write-Error -Message "Access denied to $Computer" -Category AuthenticationError -Exception $_.Exception
                        $MustExit = $true
                    }
                    catch [System.Runtime.InteropServices.COMException] {
                        if ($_.Exception.ErrorCode -eq 0x800706BA) {
                            # This is instead of the "RPC Server Unavailable" error
                            Write-Warning -Message "The RPC Server is Unavailable for $Computer. Will retry every 10 seconds until [StopWatch $($StopWatch.Elapsed) -ge $Timeout minutes] Error: $($_.Exception.Message)"
                            $MustExit = $false
                        }
                        else {
                            $_
                            $MustExit = $true
                        }
                    }        
                    catch {
                        Write-Warning "Failed to invoke the $Option cycle via WMI. Will retry every 10 seconds until [StopWatch $($StopWatch.Elapsed) -ge $Timeout minutes] Error: $($_.Exception.Message)"
                        Start-Sleep -Seconds 10
                    }
                }
                until ($Invocation -or $StopWatch.Elapsed -ge $TimeSpan -or $MustExit)
                if ($Invocation) {
                    Write-Verbose "Successfully invoked the $Option Cycle on $Computer via the 'TriggerSchedule' WMI method"
                    Start-Sleep -Seconds $Delay
                }
                elseif ($StopWatch.Elapsed -ge $TimeSpan -or $MustExit) {
                    Write-Error "Failed to invoke $Option cycle via WMI after $Timeout minutes of retrying."
                }
                $StopWatch.Reset()    
            }
        }
    }
    end {
        Write-Verbose "Following actions invoked - $Schedule"
    }
}
