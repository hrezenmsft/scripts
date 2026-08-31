<#
.SYNOPSIS
Samples Windows TCP connections and UDP endpoints into CSV logs.

.DESCRIPTION
Groups TCP connections by state and owning process and UDP endpoints by owning
process. Each sample appends the largest groups and process metadata to
separate UTF-8 CSV files. The monitor runs continuously by default and can be
bounded with SampleCount.

.PARAMETER IntervalSeconds
Seconds between samples. The default is 10.

.PARAMETER OutputDirectory
Directory for TCP and UDP CSV files. When omitted, the script creates a unique
directory under the current user's temporary folder.

.PARAMETER Top
Maximum number of grouped TCP and UDP rows written per sample. The default is 25.

.PARAMETER SampleCount
Number of samples to collect. Zero means run until interrupted. The default is zero.

.EXAMPLE
.\Start-WindowsNetworkEndpointMonitor.ps1

.EXAMPLE
.\Start-WindowsNetworkEndpointMonitor.ps1 -IntervalSeconds 30 -OutputDirectory "$env:TEMP\NetworkEndpoints" -SampleCount 10

.NOTES
Author: Henrique Rezende

.LINK
https://github.com/hrezenmsft/windows-network-diagnostic-tools
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 86400)]
    [int]$IntervalSeconds = 10,

    [string]$OutputDirectory,

    [ValidateRange(1, 1000)]
    [int]$Top = 25,

    [ValidateRange(0, 1000000)]
    [int]$SampleCount = 0
)

foreach ($commandName in @("Get-NetTCPConnection", "Get-NetUDPEndpoint", "Get-CimInstance")) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found. This monitor requires Windows network and CIM cmdlets."
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $runDirectoryName = "WindowsNetworkEndpointMonitor-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $OutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) $runDirectoryName
}

$resolvedOutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $resolvedOutputDirectory -PathType Container)) {
    $null = New-Item -Path $resolvedOutputDirectory -ItemType Directory -Force -ErrorAction Stop
}

$tcpOutputPath = Join-Path $resolvedOutputDirectory "tcp-connection-groups.csv"
$udpOutputPath = Join-Path $resolvedOutputDirectory "udp-endpoint-groups.csv"

Write-Host "Network endpoint monitor logs" -ForegroundColor Cyan
Write-Host "  Directory: $resolvedOutputDirectory"
Write-Host "  TCP: $tcpOutputPath"
Write-Host "  UDP: $udpOutputPath"
Write-Host ""

function Get-EndpointProcessInfo {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [hashtable]$Cache
    )

    if ($Cache.ContainsKey($ProcessId)) {
        return $Cache[$ProcessId]
    }

    $processName = "N/A"
    $commandLine = "N/A"
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $processName = $process.ProcessName
        $cimProcess = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$cimProcess.CommandLine)) {
            $commandLine = [string]$cimProcess.CommandLine
        }
    }
    catch {
        # A process can exit between endpoint enumeration and metadata lookup.
    }

    $details = [PSCustomObject]@{
        ProcessName = $processName
        CommandLine = $commandLine
    }
    $Cache[$ProcessId] = $details
    $details
}

$sampleNumber = 0
do {
    $sampleNumber++
    $sampledAtUTC = (Get-Date).ToUniversalTime().ToString("o")
    $processCache = @{}

    $tcpGroups = @(
        Get-NetTCPConnection -ErrorAction Stop |
            Group-Object -Property State, OwningProcess |
            Sort-Object Count -Descending |
            Select-Object -First $Top
    )
    $tcpRows = @(
        foreach ($group in $tcpGroups) {
            $endpoint = $group.Group[0]
            $processId = [int]$endpoint.OwningProcess
            $processInfo = Get-EndpointProcessInfo -ProcessId $processId -Cache $processCache
            [PSCustomObject]@{
                SampledAtUTC = $sampledAtUTC
                SampleNumber = $sampleNumber
                Protocol = "TCP"
                Count = $group.Count
                State = [string]$endpoint.State
                OwningProcess = $processId
                ProcessName = $processInfo.ProcessName
                CommandLine = $processInfo.CommandLine
            }
        }
    )

    $udpGroups = @(
        Get-NetUDPEndpoint -ErrorAction Stop |
            Group-Object -Property OwningProcess |
            Sort-Object Count -Descending |
            Select-Object -First $Top
    )
    $udpRows = @(
        foreach ($group in $udpGroups) {
            $endpoint = $group.Group[0]
            $processId = [int]$endpoint.OwningProcess
            $processInfo = Get-EndpointProcessInfo -ProcessId $processId -Cache $processCache
            [PSCustomObject]@{
                SampledAtUTC = $sampledAtUTC
                SampleNumber = $sampleNumber
                Protocol = "UDP"
                Count = $group.Count
                State = "Endpoint"
                OwningProcess = $processId
                ProcessName = $processInfo.ProcessName
                CommandLine = $processInfo.CommandLine
            }
        }
    )

    if ($tcpRows.Count -gt 0) {
        $tcpRows | Export-Csv -LiteralPath $tcpOutputPath -NoTypeInformation -Encoding UTF8 -Append
    }
    if ($udpRows.Count -gt 0) {
        $udpRows | Export-Csv -LiteralPath $udpOutputPath -NoTypeInformation -Encoding UTF8 -Append
    }

    Write-Host "Sample $sampleNumber written at $sampledAtUTC ($($tcpRows.Count) TCP groups, $($udpRows.Count) UDP groups)."
    if ($SampleCount -eq 0 -or $sampleNumber -lt $SampleCount) {
        Start-Sleep -Seconds $IntervalSeconds
    }
} while ($SampleCount -eq 0 -or $sampleNumber -lt $SampleCount)

Write-Host "TCP log: $tcpOutputPath"
Write-Host "UDP log: $udpOutputPath"