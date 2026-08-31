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
Reports Azure VM running time for one selected reporting window.

.DESCRIPTION
Calculates running periods and total uptime for a selected Azure VM using
successful start and deallocate Activity Log events, VM creation time, and the
current VM power state. All report timestamps are UTC. A VM that was already
running when the reporting window began is reported as having run for at least
the window duration; Azure Activity Log data cannot determine its guest OS boot
time. Use IncludeGuestUptime to retrieve Linux guest uptime through Azure Run
Command.

An active Azure CLI session is required. The script never runs az login; if the
session is missing or expired, it stops and instructs the user to run az login.

.PARAMETER VMName
Name of the virtual machine. VM is an alias for this parameter. When omitted,
the script prompts for a value.

.PARAMETER ResourceGroupName
Name of the resource group containing the VM. RG is an alias for this
parameter. When omitted, the script prompts for a value.

.PARAMETER DaysAgo
Number of days to include in the report. The default is 30 and the accepted
range is 1 through 90.

.PARAMETER IncludeGuestUptime
Retrieves Linux guest uptime through Azure Run Command. Requires a running VM,
the Azure VM agent, and permission for Microsoft.Compute/virtualMachines/runCommand/action.

.EXAMPLE
.\Get-AzVmUptimeSingle.ps1 -VMName "example-vm" -ResourceGroupName "example-rg"

Reports the previous 30 days for example-vm.

.EXAMPLE
.\Get-AzVmUptimeSingle.ps1 -VM "example-vm" -RG "example-rg" -DaysAgo 7

Reports the previous seven days for example-vm using parameter aliases.

.EXAMPLE
.\Get-AzVmUptimeSingle.ps1 -VM "example-vm" -RG "example-rg" -IncludeGuestUptime

Reports the selected window and actual Linux guest uptime.

.NOTES
Author: Henrique Rezende
Version: 1.0.0

.LINK
https://github.com/hrezenmsft/azure-vm-uptime-tools
#>

[CmdletBinding()]
param(
    [Alias("VM")]
    [string]$VMName,

    [Alias("RG")]
    [string]$ResourceGroupName,

    [ValidateRange(1, 90)]
    [int]$DaysAgo = 30,

    [switch]$IncludeGuestUptime
)

while ([string]::IsNullOrWhiteSpace($vmName)) {
    $vmName = Read-Host "Enter the VM name"
}

while ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
    $resourceGroupName = Read-Host "Enter the resource group name"
}

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

# Get the current date and the date X days ago
$currentDate = Get-Date
$currentDateUTC = $currentDate.ToUniversalTime()
$startDate = $currentDate.AddDays(-$daysAgo)
$startDateUTC = ($startDate).ToUniversalTime()
$queryEndUTC = $currentDateUTC

# Initialize a list to store the running periods for the VM
$runningPeriods = @()
$totalDuration = [TimeSpan]::Zero

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

# Determine the status of the VM
$vm = Get-AzVM -ResourceGroupName $resourceGroupName -Name $vmName -Status
$portalState = $vm.Statuses | Where-Object Code -match "PowerState" | Select-Object -ExpandProperty DisplayStatus

$guestUptime = $null
if ($IncludeGuestUptime) {
    if ($portalState -ne 'VM running') {
        $guestUptime = 'Unavailable (VM is not running)'
    }
    else {
        $osType = az vm show --resource-group $resourceGroupName --name $vmName --subscription $subscriptionId --query 'storageProfile.osDisk.osType' --output tsv --only-show-errors
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($osType)) {
            $guestUptime = 'Unavailable (could not determine OS type)'
        }
        elseif ($osType -ne 'Linux') {
            $guestUptime = 'Unavailable (Linux only)'
        }
        else {
            $guestUptime = Get-LinuxGuestUptime -ResourceGroupName $resourceGroupName -VmName $vmName -SubscriptionId $subscriptionId
        }
    }
}

# Get the activity log for the VM
$resourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Compute/virtualMachines/$vmName"
$activityLogJson = az monitor activity-log list --resource-id $resourceId --start-time $startDateUTC.ToString("yyyy-MM-ddTHH:mm:ssZ") --end-time $currentDateUTC.ToString("yyyy-MM-ddTHH:mm:ssZ") --max-events 1000 --subscription $subscriptionId --output json --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve the activity log for VM '$vmName'."
}

$operationNames = @{
    "Microsoft.Compute/virtualMachines/start/action" = "Start Virtual Machine"
    "Microsoft.Compute/virtualMachines/deallocate/action" = "Deallocate Virtual Machine"
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

# VM creation powers on a new VM but does not emit a separate Start Virtual Machine event.
$vmCreatedText = az vm show --resource-group $resourceGroupName --name $vmName --subscription $subscriptionId --query timeCreated --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vmCreatedText)) {
    throw "Unable to determine the creation time of VM '$vmName'."
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

# Refresh the report cutoff after Azure calls so open periods never use a stale end time.
$currentDate = Get-Date
$currentDateUTC = $currentDate.ToUniversalTime()

# Initialize variables to track the running periods
$running = $false
$startTime = $null
$isWindowLimited = $false

if ($activityEvents) {
    # Loop through the events to determine the running periods
    foreach ($activityEvent in $activityEvents) {
        if ($activityEvent.OperationName -eq "Start Virtual Machine" -and $running -eq $false) {
            $running = $true
            $startTime = $activityEvent.EventTimestamp
        } elseif ($activityEvent.OperationName -eq "Deallocate Virtual Machine" -and $running) {
            $running = $false
            $endTime = $activityEvent.EventTimestamp
            $duration = $endTime - $startTime
            $totalDuration += $duration
            # Add the running period to the list
            $runningPeriods += [PSCustomObject]@{
                StartTime = $startTime.ToString("u")
                EndTime = $endTime.ToString("u")
                Duration = "{0}h {1}m" -f [math]::Floor($duration.TotalHours), [math]::Floor($duration.TotalMinutes % 60)
            }
        }
    }
    # Handle currently running VM
    if ($running -and $startTime) {
        if ($startTime -gt $currentDateUTC) {
            throw "The latest start event '$($startTime.ToString('u'))' is later than the current UTC time '$($currentDateUTC.ToString('u'))'. Check the event timestamp and system clock."
        }
        $duration = $currentDateUTC - $startTime
        $totalDuration += $duration
        # Add the running period to the list
        $runningPeriods += [PSCustomObject]@{
            StartTime = $startTime.ToString("u")
            EndTime = "Currently Running"
            Duration = "{0}h {1}m" -f [math]::Floor($duration.TotalHours), [math]::Floor($duration.TotalMinutes % 60)
        }
    }

} else {
    # If VM had no events and is currently deallocated, total running time in the period is 0.
    # If VM had no events and is currently RUNNING, total running time is the full period.
    if ($portalState -eq "VM Running") {
        $duration = $currentDateUTC - $startDateUTC
        $totalDuration += $duration
        $isWindowLimited = $true
        # Add the running period to the list
        $runningPeriods += [PSCustomObject]@{
            StartTime = $startDateUTC.ToString("u")
            EndTime = "Currently Running"
            Duration = "{0}h {1}m" -f [math]::Floor($duration.TotalHours), [math]::Floor($duration.TotalMinutes % 60)
        }
    }
}

# Output the running periods for the VM
Write-Host "Uptime report for VM '$vmName' in resource group '$resourceGroupName' (last $DaysAgo days)" -ForegroundColor Yellow
Write-Host "Queried period (UTC): $($startDateUTC.ToString('u')) to $($queryEndUTC.ToString('u'))"
Write-Host "Running periods:" -ForegroundColor Yellow
$runningPeriods | Format-Table -AutoSize

# Output the total running time for the VM within the selected window.
$totalUptime = Format-UptimeDuration -Duration $totalDuration
if ($isWindowLimited) {
    $totalUptime = "At least $totalUptime (running when window began)"
}
Write-Host "Total running time within the reporting window: $totalUptime"
if ($IncludeGuestUptime) {
    Write-Host "Linux guest uptime: $guestUptime"
}
Write-Host "Report generated on $currentDateUTC (UTC)."