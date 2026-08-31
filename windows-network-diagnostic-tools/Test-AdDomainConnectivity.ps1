<#
.SYNOPSIS
Tests TCP connectivity to common Active Directory domain services.

.DESCRIPTION
Discovers a domain controller with nltest.exe, unless one is supplied, and
tests TCP connectivity to common AD DS service ports. Results are returned as
objects, summarized in the terminal, and can optionally be exported to CSV.
This is a reachability test; it does not validate authentication or
application-level service health.

.PARAMETER DomainName
DNS name of the Active Directory domain.

.PARAMETER DomainController
Optional domain controller host name or IP address. When omitted, nltest.exe
discovers a domain controller for DomainName.

.PARAMETER OutputPath
Optional CSV destination path.

.EXAMPLE
.\Test-AdDomainConnectivity.ps1 -DomainName contoso.com

.EXAMPLE
.\Test-AdDomainConnectivity.ps1 -DomainName contoso.com -DomainController dc01.contoso.com -OutputPath .\ad-connectivity.csv

.NOTES
Author: Henrique Rezende

.LINK
https://github.com/hrezenmsft/windows-network-diagnostic-tools
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias("Domain")]
    [ValidateNotNullOrEmpty()]
    [string]$DomainName,

    [string]$DomainController,

    [string]$OutputPath
)

if (-not (Get-Command Test-NetConnection -ErrorAction SilentlyContinue)) {
    throw "Test-NetConnection is required and is available only on Windows."
}

$discoveredAddress = $null
if ([string]::IsNullOrWhiteSpace($DomainController)) {
    if (-not (Get-Command nltest.exe -ErrorAction SilentlyContinue)) {
        throw "nltest.exe is required when DomainController is not supplied."
    }

    $nltestOutput = & nltest.exe "/dsgetdc:$DomainName" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "nltest.exe could not discover a domain controller for '$DomainName': $($nltestOutput -join ' ')"
    }

    $dcLine = $nltestOutput | Select-String -Pattern "^\s*DC:\s+\\\\(.+?)\s*$" | Select-Object -First 1
    if (-not $dcLine -or $dcLine.Matches.Count -eq 0) {
        throw "nltest.exe output did not contain a domain controller name."
    }
    $DomainController = $dcLine.Matches[0].Groups[1].Value.Trim()

    $addressLine = $nltestOutput | Select-String -Pattern "^\s*Address:\s+\\\\(.+?)\s*$" | Select-Object -First 1
    if ($addressLine -and $addressLine.Matches.Count -gt 0) {
        $discoveredAddress = $addressLine.Matches[0].Groups[1].Value.Trim()
    }
}

$services = @(
    [PSCustomObject]@{ Port = 53; Service = "DNS" }
    [PSCustomObject]@{ Port = 88; Service = "Kerberos" }
    [PSCustomObject]@{ Port = 135; Service = "RPC Endpoint Mapper" }
    [PSCustomObject]@{ Port = 389; Service = "LDAP" }
    [PSCustomObject]@{ Port = 445; Service = "SMB" }
    [PSCustomObject]@{ Port = 636; Service = "LDAPS" }
    [PSCustomObject]@{ Port = 3268; Service = "Global Catalog LDAP" }
    [PSCustomObject]@{ Port = 3269; Service = "Global Catalog LDAPS" }
)

$testedAtUTC = (Get-Date).ToUniversalTime().ToString("o")
$results = @(
    foreach ($service in $services) {
        $reachable = Test-NetConnection -ComputerName $DomainController -Port $service.Port -InformationLevel Quiet -WarningAction SilentlyContinue
        [PSCustomObject]@{
            TestedAtUTC = $testedAtUTC
            DomainName = $DomainName
            DomainController = $DomainController
            DiscoveredAddress = $discoveredAddress
            Port = $service.Port
            Service = $service.Service
            TcpReachable = [bool]$reachable
        }
    }
)

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $outputDirectory = Split-Path -Parent $resolvedOutputPath
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        throw "The output directory '$outputDirectory' does not exist."
    }
    $results | Export-Csv -LiteralPath $resolvedOutputPath -NoTypeInformation -Encoding UTF8
}

$results

$reachableResults = @($results | Where-Object TcpReachable)
$unreachableResults = @($results | Where-Object { -not $_.TcpReachable })
$successPercentage = if ($results.Count -gt 0) {
    [Math]::Round(($reachableResults.Count / $results.Count) * 100, 1)
}
else {
    0
}

Write-Host ""
Write-Host "AD connectivity summary" -ForegroundColor Cyan
Write-Host "  Domain: $DomainName"
Write-Host "  Domain controller: $DomainController"
if (-not [string]::IsNullOrWhiteSpace($discoveredAddress)) {
    Write-Host "  Discovered address: $discoveredAddress"
}
Write-Host "  Tested services: $($results.Count)"
Write-Host "  Reachable: $($reachableResults.Count)" -ForegroundColor Green
$unreachableColor = if ($unreachableResults.Count -gt 0) { "Red" } else { "Green" }
Write-Host "  Unreachable: $($unreachableResults.Count)" -ForegroundColor $unreachableColor
Write-Host "  Success rate: $successPercentage%"
Write-Host ""
Write-Host "Port / service connectivity" -ForegroundColor Cyan
foreach ($result in $results) {
    $status = if ($result.TcpReachable) { "Reachable" } else { "Unreachable" }
    $statusColor = if ($result.TcpReachable) { "Green" } else { "Red" }
    Write-Host ("  TCP/{0,-5} {1,-24} {2}" -f $result.Port, $result.Service, $status) -ForegroundColor $statusColor
}
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    Write-Host ""
    Write-Host "  CSV: $resolvedOutputPath"
}