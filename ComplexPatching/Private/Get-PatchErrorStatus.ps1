function Get-PatchErrorStatus {
    [OutputType([boolean])]
    param
    (
        [parameter(Mandatory = $true)]
        [array]$UpdateArray
    )
    $UpdateArray.EvaluationState -contains '13' -or $Update.LastAction -contains 'Error'
}