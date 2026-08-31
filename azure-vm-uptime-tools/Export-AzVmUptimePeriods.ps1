<#
Disclaimer
The sample scripts are not supported under any Microsoft standard support program or service.
The sample scripts are provided AS IS without warranty of any kind. Microsoft further disclaims
all implied warranties including, without limitation, any implied warranties of merchantability
or of fitness for a particular purpose. The entire risk arising out of the use or performance of
the sample scripts and documentation remains with you. In no event shall Microsoft, its authors,
or anyone else involved in the creation, production, or delivery of the scripts be liable for any
damages whatsoever (including, without limitation, damages for loss of business profits, business
interruption, loss of business information, or other pecuniary loss) arising out of the use of or
inability to use the sample scripts or documentation, even if Microsoft has been advised of the
possibility of such damages.
#>

<#
.SYNOPSIS
Exports Azure VM running periods to a CSV file.

.DESCRIPTION
Creates a CSV report of detected running periods for every VM in the active
Azure subscription. The report uses successful start and deallocate Activity
Log events, VM creation time, and current VM power state. All timestamps are
UTC and the default lookback period is 30 days.

An active Azure CLI session is required. The script never runs az login; if the
session is missing or expired, it stops and instructs the user to run az login.

.PARAMETER DaysAgo
Number of days to include in the report. The default is 30 and the accepted
range is 1 through 90.

.PARAMETER OutputPath
Path of the CSV file to create. When omitted, a timestamped file is created in
the current directory.

.EXAMPLE
.\Export-AzVmUptimePeriods.ps1

Exports the previous 30 days to a timestamped CSV file in the current directory.

.EXAMPLE
.\Export-AzVmUptimePeriods.ps1 -DaysAgo 7 -OutputPath .\uptime-periods.csv

Exports the previous seven days to uptime-periods.csv.

.NOTES
Author: Henrique Rezende
Version: 1.0.0

.LINK
https://github.com/hrezenmsft/azure-vm-uptime-tools
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 90)]
    [int]$DaysAgo = 30,

    [string]$OutputPath
)

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI is required. Install it and try again."
}

$null = az account get-access-token --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "No valid Azure CLI session was found. Run 'az login', select the required subscription, and then run this script again."
}

$azAccount = az account show --output json 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $azAccount.id) {
    throw "Azure CLI has no active subscription. Run 'az account set --subscription <subscription-name-or-id>' and try again."
}

$accessToken = az account get-access-token --subscription $azAccount.id --query accessToken --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
    throw "Azure CLI could not acquire an access token for the active subscription."
}

Connect-AzAccount -AccessToken $accessToken -AccountId $azAccount.user.name -Tenant $azAccount.tenantId -Subscription $azAccount.id -ErrorAction Stop | Out-Null
$subscriptionId = $azAccount.id

$queryEndUTC = (Get-Date).ToUniversalTime()
$queryStartUTC = $queryEndUTC.AddDays(-$DaysAgo)

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $fileName = "azure-vm-uptime-periods-$($queryEndUTC.ToString('yyyyMMddTHHmmssZ')).csv"
    $OutputPath = Join-Path (Get-Location) $fileName
}

$resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "The output directory '$outputDirectory' does not exist."
}

$vms = @(Get-AzVM -Status | Sort-Object ResourceGroupName, Name)
if ($vms.Count -eq 0) {
    Write-Host "No virtual machines were found in subscription '$subscriptionId'." -ForegroundColor Yellow
}

$operationNames = @{
    "Microsoft.Compute/virtualMachines/start/action" = "Start Virtual Machine"
    "Microsoft.Compute/virtualMachines/deallocate/action" = "Deallocate Virtual Machine"
}

$allRunningPeriods = @()
$progress = 0

foreach ($vm in $vms) {
    $progress++
    $vmName = $vm.Name
    $resourceGroupName = $vm.ResourceGroupName
    Write-Progress -Activity "Processing VMs" -Status "Processing $vmName [$progress / $($vms.Count)]" -PercentComplete (($progress / $vms.Count) * 100)

    $portalState = $vm.Statuses | Where-Object Code -match "PowerState" | Select-Object -ExpandProperty DisplayStatus
    if ([string]::IsNullOrWhiteSpace($portalState) -and $vm.PowerState) {
        $portalState = $vm.PowerState
    }

    $activityLogJson = az monitor activity-log list --resource-id $vm.Id --start-time $queryStartUTC.ToString("yyyy-MM-ddTHH:mm:ssZ") --end-time $queryEndUTC.ToString("yyyy-MM-ddTHH:mm:ssZ") --max-events 1000 --subscription $subscriptionId --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to retrieve the activity log for VM '$vmName' in resource group '$resourceGroupName'."
    }

    $activityEvents = @(
        $activityLogJson | ConvertFrom-Json -ErrorAction Stop | ForEach-Object {
            $operationName = [string]$_.operationName.value
            if ($operationNames.ContainsKey($operationName) -and $_.status.value -eq "Succeeded") {
                $activityTimestamp = if ($_.eventTimestamp -is [DateTime]) {
                    $_.eventTimestamp.ToUniversalTime()
                }
                else {
                    ([DateTimeOffset]::Parse([string]$_.eventTimestamp)).UtcDateTime
                }

                [PSCustomObject]@{
                    OperationName = $operationNames[$operationName]
                    EventTimestamp = $activityTimestamp
                    CorrelationId = [string]$_.correlationId
                }
            }
        } | Sort-Object CorrelationId -Unique
    )

    # VM creation powers on a new VM but does not emit a separate start event.
    $vmCreatedText = az vm show --resource-group $resourceGroupName --name $vmName --subscription $subscriptionId --query timeCreated --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vmCreatedText)) {
        throw "Unable to determine the creation time of VM '$vmName' in resource group '$resourceGroupName'."
    }

    $vmCreatedUTC = ([DateTimeOffset]::Parse($vmCreatedText)).UtcDateTime
    if ($vmCreatedUTC -ge $queryStartUTC -and $vmCreatedUTC -le $queryEndUTC) {
        $activityEvents += [PSCustomObject]@{
            OperationName = "Start Virtual Machine"
            EventTimestamp = $vmCreatedUTC
            CorrelationId = "VM-Creation"
        }
    }

    $activityEvents = @($activityEvents | Sort-Object EventTimestamp)
    $running = $false
    $startTime = $null

    # A deallocate event as the first transition means the VM was running when the window opened.
    if ($activityEvents.Count -gt 0 -and $activityEvents[0].OperationName -eq "Deallocate Virtual Machine") {
        $running = $true
        $startTime = $queryStartUTC
    }

    foreach ($activityEvent in $activityEvents) {
        if ($activityEvent.OperationName -eq "Start Virtual Machine" -and -not $running) {
            $running = $true
            $startTime = $activityEvent.EventTimestamp
        }
        elseif ($activityEvent.OperationName -eq "Deallocate Virtual Machine" -and $running) {
            $running = $false
            $endTime = $activityEvent.EventTimestamp
            $duration = $endTime - $startTime
            $allRunningPeriods += [PSCustomObject]@{
                SubscriptionId = $subscriptionId
                ResourceGroupName = $resourceGroupName
                VMName = $vmName
                CurrentPowerState = $portalState
                QueryStartUTC = $queryStartUTC.ToString("o")
                QueryEndUTC = $queryEndUTC.ToString("o")
                PeriodStartUTC = $startTime.ToString("o")
                PeriodEndUTC = $endTime.ToString("o")
                DurationHours = [math]::Round($duration.TotalHours, 2)
                DurationMinutes = [math]::Round($duration.TotalMinutes, 2)
                IsOpenPeriod = $false
            }
        }
    }

    if ($running -and $startTime) {
        $duration = $queryEndUTC - $startTime
        $allRunningPeriods += [PSCustomObject]@{
            SubscriptionId = $subscriptionId
            ResourceGroupName = $resourceGroupName
            VMName = $vmName
            CurrentPowerState = $portalState
            QueryStartUTC = $queryStartUTC.ToString("o")
            QueryEndUTC = $queryEndUTC.ToString("o")
            PeriodStartUTC = $startTime.ToString("o")
            PeriodEndUTC = $queryEndUTC.ToString("o")
            DurationHours = [math]::Round($duration.TotalHours, 2)
            DurationMinutes = [math]::Round($duration.TotalMinutes, 2)
            IsOpenPeriod = $true
        }
    }
    elseif ($activityEvents.Count -eq 0 -and $portalState -eq "VM Running") {
        $duration = $queryEndUTC - $queryStartUTC
        $allRunningPeriods += [PSCustomObject]@{
            SubscriptionId = $subscriptionId
            ResourceGroupName = $resourceGroupName
            VMName = $vmName
            CurrentPowerState = $portalState
            QueryStartUTC = $queryStartUTC.ToString("o")
            QueryEndUTC = $queryEndUTC.ToString("o")
            PeriodStartUTC = $queryStartUTC.ToString("o")
            PeriodEndUTC = $queryEndUTC.ToString("o")
            DurationHours = [math]::Round($duration.TotalHours, 2)
            DurationMinutes = [math]::Round($duration.TotalMinutes, 2)
            IsOpenPeriod = $true
        }
    }
}

Write-Progress -Activity "Processing VMs" -Completed

if ($allRunningPeriods.Count -gt 0) {
    $allRunningPeriods | Export-Csv -LiteralPath $resolvedOutputPath -NoTypeInformation -Encoding UTF8
}
else {
    $emptyReportTemplate = [PSCustomObject]@{
        SubscriptionId = ""
        ResourceGroupName = ""
        VMName = ""
        CurrentPowerState = ""
        QueryStartUTC = ""
        QueryEndUTC = ""
        PeriodStartUTC = ""
        PeriodEndUTC = ""
        DurationHours = ""
        DurationMinutes = ""
        IsOpenPeriod = ""
    }
    $emptyReportTemplate | ConvertTo-Csv -NoTypeInformation | Select-Object -First 1 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
}

Write-Host "Azure VM uptime period report created." -ForegroundColor Green
Write-Host "Subscription: $subscriptionId"
Write-Host "Queried period (UTC): $($queryStartUTC.ToString('u')) to $($queryEndUTC.ToString('u'))"
Write-Host "Running periods exported: $($allRunningPeriods.Count)"
Write-Host "CSV file: $resolvedOutputPath"