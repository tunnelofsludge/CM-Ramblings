function Get-FQDNFromDB {
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        [parameter(Mandatory = $true)]
        [string]$SQLServer,
        [parameter(Mandatory = $true)]
        [string]$Database
    )
    $startCompPatchQuerySplat = @{
        Query     = "SELECT [Domain] FROM [dbo].[ServerStatus] WHERE [ServerName] = '$ComputerName'"
        SQLServer = $SQLServer
        Database  = $Database
    }
    $Domain = Start-CompPatchQuery @startCompPatchQuerySplat | Select-Object -ExpandProperty Domain
    [string]::Format("{0}.{1}", $ComputerName, $Domain)
}