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
Reports Azure VM running time within a selected reporting window.

.DESCRIPTION
Calculates running periods and total uptime for every VM in a selected resource
group or for every VM in the active Azure subscription. When no resource group
is provided, the script prompts for a resource group or all resource groups.
The report uses successful start and deallocate Activity Log events, VM creation
time, and current VM power state. All timestamps are UTC. A VM that was already
running when the reporting window began is reported as having run for at least
the window duration; Azure Activity Log data cannot determine its guest OS boot
time. Use IncludeGuestUptime to retrieve Linux guest uptime through Azure Run
Command.

An active Azure CLI session is required. The script never runs az login; if the
session is missing or expired, it stops and instructs the user to run az login.

.PARAMETER ResourceGroupName
Limits the report to a resource group. When omitted, the script prompts for a
resource group or all resource groups. RG is an alias for this parameter.

.PARAMETER DaysAgo
Number of days to include in the report. The default is 90 and the accepted
range is 1 through 90. Azure Activity Log queries cannot start more than 90
days in the past.

.PARAMETER IncludeGuestUptime
Retrieves Linux guest uptime through Azure Run Command. Requires a running VM,
the Azure VM agent, and permission for Microsoft.Compute/virtualMachines/runCommand/action.

.EXAMPLE
.\Get-AzVmUptimeSummary.ps1

Prompts for a resource group or all resource groups, then reports the previous
30 days for the selected scope.

.EXAMPLE
.\Get-AzVmUptimeSummary.ps1 -ResourceGroupName "example-rg" -DaysAgo 7

Reports the previous seven days for all VMs in example-rg.

.EXAMPLE
.\Get-AzVmUptimeSummary.ps1 -ResourceGroupName "example-rg" -IncludeGuestUptime

Adds actual Linux guest uptime to the per-VM summary.

.NOTES
Author: Henrique Rezende
Version: 1.1.2

.LINK
https://github.com/hrezenmsft/azure-vm-uptime-tools
#>

[CmdletBinding()]
param(
    [Alias("RG")]
    [string]$ResourceGroupName,

    [ValidateRange(1, 90)]
    [int]$DaysAgo = 90,

    [switch]$IncludeGuestUptime
)

# Verify that Azure CLI is installed and has a valid session.
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

$currentDateUTC = (Get-Date).ToUniversalTime()
$startDateUTC = $currentDateUTC.AddDays(-$DaysAgo)

# Get VM status once for the requested scope.
if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $allVms = @(Get-AzVM -Status | Sort-Object ResourceGroupName, Name)
    $resourceGroupNames = @($allVms | Select-Object -ExpandProperty ResourceGroupName -Unique)

    if ($allVms.Count -eq 0) {
        Write-Host "No virtual machines were found in subscription '$subscriptionId'." -ForegroundColor Yellow
        return
    }

    Write-Host "Select the VM scope:" -ForegroundColor Cyan
    Write-Host "  0. All resource groups"
    for ($index = 0; $index -lt $resourceGroupNames.Count; $index++) {
        Write-Host "  $($index + 1). $($resourceGroupNames[$index])"
    }

    do {
        $selection = Read-Host "Enter a number (0-$($resourceGroupNames.Count))"
        $selectionNumber = 0
        $validSelection = [int]::TryParse($selection, [ref]$selectionNumber) -and
            $selectionNumber -ge 0 -and $selectionNumber -le $resourceGroupNames.Count

        if (-not $validSelection) {
            Write-Host "Enter a valid number from 0 to $($resourceGroupNames.Count)." -ForegroundColor Yellow
        }
    } until ($validSelection)

    if ($selectionNumber -eq 0) {
        $vms = $allVms
        $scopeDescription = "subscription '$subscriptionId'"
    }
    else {
        $ResourceGroupName = $resourceGroupNames[$selectionNumber - 1]
        $vms = @($allVms | Where-Object ResourceGroupName -eq $ResourceGroupName)
        $scopeDescription = "resource group '$ResourceGroupName'"
    }
}
else {
    $vms = @(Get-AzVM -ResourceGroupName $ResourceGroupName -Status | Sort-Object Name)
    $scopeDescription = "resource group '$ResourceGroupName'"
}

if ($vms.Count -eq 0) {
    Write-Host "No virtual machines were found in $scopeDescription." -ForegroundColor Yellow
    return
}

$operationNames = @{
    "Microsoft.Compute/virtualMachines/start/action" = "Start Virtual Machine"
    "Microsoft.Compute/virtualMachines/deallocate/action" = "Deallocate Virtual Machine"
}

$allRunningPeriods = @()
$vmUptimeSummary = @()
$totalDurationAllVMs = [TimeSpan]::Zero
$progress = 0

function Format-UptimeDuration {
    param(
        [Parameter(Mandatory)]
        [TimeSpan]$Duration
    )

    if ($Duration.TotalDays -ge 1) {
        return "{0}d {1}h {2}m" -f [math]::Floor($Duration.TotalDays), $Duration.Hours, $Duration.Minutes
    }

    return "{0}h {1}m" -f [math]::Floor($Duration.TotalHours), $Duration.Minutes
}

function Get-LinuxGuestUptime {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    $uptimeSeconds = az vm run-command invoke --resource-group $ResourceGroupName --name $VmName --command-id RunShellScript --scripts 'cut -d. -f1 /proc/uptime' --subscription $SubscriptionId --query 'value[0].message' --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        return 'Unavailable (Run Command failed)'
    }

    $uptimeMessage = $uptimeSeconds -join [Environment]::NewLine
    $uptimeMatch = [regex]::Match($uptimeMessage, '(?m)^\s*(?<seconds>\d+)(?:\.\d+)?\s*$')
    if (-not $uptimeMatch.Success) {
        return 'Unavailable (invalid guest response)'
    }

    $parsedUptimeSeconds = 0L
    if (-not [long]::TryParse($uptimeMatch.Groups['seconds'].Value, [ref]$parsedUptimeSeconds) -or $parsedUptimeSeconds -lt 0) {
        return 'Unavailable (invalid guest response)'
    }

    return Format-UptimeDuration -Duration ([TimeSpan]::FromSeconds($parsedUptimeSeconds))
}

foreach ($vm in $vms) {
    $progress++
    $vmName = $vm.Name
    $vmResourceGroupName = $vm.ResourceGroupName
    Write-Progress -Activity "Processing VMs" -Status "Processing $vmName [$progress / $($vms.Count)]" -PercentComplete (($progress / $vms.Count) * 100)

    $portalState = $vm.Statuses | Where-Object Code -match "PowerState" | Select-Object -ExpandProperty DisplayStatus
    if ([string]::IsNullOrWhiteSpace($portalState) -and $vm.PowerState) {
        $portalState = $vm.PowerState
    }

    $guestUptime = 'Not requested'
    if ($IncludeGuestUptime) {
        if ($portalState -ne 'VM running') {
            $guestUptime = 'Unavailable (VM is not running)'
        }
        elseif ($vm.StorageProfile.OsDisk.OsType -ne 'Linux') {
            $guestUptime = 'Unavailable (Linux only)'
        }
        else {
            $guestUptime = Get-LinuxGuestUptime -ResourceGroupName $vmResourceGroupName -VmName $vmName -SubscriptionId $subscriptionId
        }
    }

    $resourceId = $vm.Id
    $activityLogJson = az monitor activity-log list --resource-id $resourceId --start-time $startDateUTC.ToString("yyyy-MM-ddTHH:mm:ssZ") --end-time $currentDateUTC.ToString("yyyy-MM-ddTHH:mm:ssZ") --max-events 1000 --subscription $subscriptionId --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to retrieve the activity log for VM '$vmName' in resource group '$vmResourceGroupName'."
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
    $vmCreatedText = az vm show --resource-group $vmResourceGroupName --name $vmName --subscription $subscriptionId --query timeCreated --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vmCreatedText)) {
        throw "Unable to determine the creation time of VM '$vmName' in resource group '$vmResourceGroupName'."
    }

    $vmCreatedUTC = ([DateTimeOffset]::Parse($vmCreatedText)).UtcDateTime
    if ($vmCreatedUTC -ge $startDateUTC -and $vmCreatedUTC -le $currentDateUTC) {
        $activityEvents += [PSCustomObject]@{
            OperationName = "Start Virtual Machine"
            EventTimestamp = $vmCreatedUTC
            CorrelationId = "VM-Creation"
        }
    }

    $activityEvents = @($activityEvents | Sort-Object EventTimestamp)
    $reportCutoffUTC = (Get-Date).ToUniversalTime()
    $runningPeriods = @()
    $totalDuration = [TimeSpan]::Zero
    $isWindowLimited = $false
    $running = $false
    $startTime = $null

    if ($activityEvents.Count -gt 0) {
        foreach ($activityEvent in $activityEvents) {
            if ($activityEvent.OperationName -eq "Start Virtual Machine" -and -not $running) {
                $running = $true
                $startTime = $activityEvent.EventTimestamp
            }
            elseif ($activityEvent.OperationName -eq "Deallocate Virtual Machine" -and $running) {
                $running = $false
                $endTime = $activityEvent.EventTimestamp
                $duration = $endTime - $startTime
                $totalDuration += $duration
                $runningPeriods += [PSCustomObject]@{
                    StartTime = $startTime.ToString("u")
                    EndTime = $endTime.ToString("u")
                    Duration = "{0}h {1}m" -f [math]::Floor($duration.TotalHours), [math]::Floor($duration.TotalMinutes % 60)
                }
            }
        }

        if ($running -and $startTime) {
            if ($startTime -gt $reportCutoffUTC) {
                throw "The latest start event for VM '$vmName' is later than the current UTC time. Check the event timestamp and system clock."
            }

            $duration = $reportCutoffUTC - $startTime
            $totalDuration += $duration
            $runningPeriods += [PSCustomObject]@{
                StartTime = $startTime.ToString("u")
                EndTime = "Currently Running"
                Duration = "{0}h {1}m" -f [math]::Floor($duration.TotalHours), [math]::Floor($duration.TotalMinutes % 60)
            }
        }
    }
    elseif ($portalState -eq "VM Running") {
        $duration = $reportCutoffUTC - $startDateUTC
        $totalDuration += $duration
        $isWindowLimited = $true
        $runningPeriods += [PSCustomObject]@{
            StartTime = $startDateUTC.ToString("u")
            EndTime = "Currently Running"
            Duration = "{0}h {1}m" -f [math]::Floor($duration.TotalHours), [math]::Floor($duration.TotalMinutes % 60)
        }
    }

    foreach ($period in $runningPeriods) {
        $allRunningPeriods += [PSCustomObject]@{
            VMName = $vmName
            ResourceGroup = $vmResourceGroupName
            StartTime = $period.StartTime
            EndTime = $period.EndTime
            Duration = $period.Duration
        }
    }

    $totalUptimeDisplay = Format-UptimeDuration -Duration $totalDuration
    if ($isWindowLimited) {
        $totalUptimeDisplay = "At least $totalUptimeDisplay (running when window began)"
    }

    $summaryEntry = [PSCustomObject]@{
        VMName = $vmName
        ResourceGroup = $vmResourceGroupName
        Status = $portalState
        TotalUptime = $totalUptimeDisplay
    }
    if ($IncludeGuestUptime) {
        $summaryEntry | Add-Member -MemberType NoteProperty -Name GuestUptime -Value $guestUptime
    }

    $vmUptimeSummary += $summaryEntry
    $totalDurationAllVMs += $totalDuration
}

Write-Progress -Activity "Processing VMs" -Completed
$reportGeneratedUTC = (Get-Date).ToUniversalTime()

Write-Host "Uptime report for $scopeDescription" -ForegroundColor Yellow
Write-Host "Queried period (UTC): $($startDateUTC.ToString('u')) to $($currentDateUTC.ToString('u'))"
Write-Host "Running periods:" -ForegroundColor Yellow
if ($allRunningPeriods.Count -gt 0) {
    $allRunningPeriods | Format-Table -AutoSize
}
else {
    Write-Host "No running periods were detected."
}

Write-Host "VM uptime summary (last $DaysAgo days):" -ForegroundColor Yellow
$vmUptimeSummary | Format-Table -AutoSize

if ($IncludeGuestUptime) {
    Write-Host "Linux guest uptime:" -ForegroundColor Yellow
    $vmUptimeSummary | Select-Object VMName, ResourceGroup, GuestUptime | Format-Table -AutoSize
}

$totalUpTimeAllVMs = Format-UptimeDuration -Duration $totalDurationAllVMs
Write-Host "Total running time within the reporting window: $totalUpTimeAllVMs"
Write-Host "Report generated on $($reportGeneratedUTC.ToString('u'))."