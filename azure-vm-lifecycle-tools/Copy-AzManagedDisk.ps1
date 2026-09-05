<#
.SYNOPSIS
Copies an Azure managed disk across regions, resource groups, and subscriptions.

.DESCRIPTION
Creates an incremental snapshot of the source disk, copies that snapshot to the
target region with a background copy, waits for the copy to reach 100 percent,
and creates a managed disk from the copied snapshot. Temporary snapshots are
deleted afterward, including after a failed copy.

This script changes resources. It requires the Azure CLI, an authenticated
session obtained with MFA (az login), and Contributor rights on both the source
and target scopes.

When -SourceDiskName is omitted the script enters an interactive mode that walks
through numbered menus for the subscription, the virtual machine, the disk
attached to that machine, and the target subscription, resource group, and region.
Unattached disks are reachable from the virtual machine menu.

Azure requires every incremental snapshot of a given disk to use the same SKU.
When existing incremental snapshots are found for the source disk, their SKU is
reused automatically, which avoids the ConflictingUserInput error raised when a
Standard_LRS snapshot is requested for a disk whose snapshot lineage is
Standard_ZRS.

.PARAMETER SourceSubscriptionId
Subscription that contains the source disk. Selected from a menu when omitted.

.PARAMETER SourceResourceGroupName
Resource group that contains the source disk. Resolved from the selected disk when omitted.

.PARAMETER SourceDiskName
One or more managed disk names to copy. Selected from a multiple-selection menu
when omitted, where [A] copies every disk attached to the chosen virtual machine.

.PARAMETER TargetSubscriptionId
Subscription that receives the disk copy. Selected from a menu in interactive
mode, otherwise defaults to the source subscription.

.PARAMETER TargetResourceGroupName
Resource group that receives the disk copy. Selected from a menu in interactive
mode, otherwise defaults to the source resource group.

.PARAMETER TargetRegion
Azure region that receives the disk copy. Selected from snapshot-capable regions
when omitted. The region must support Microsoft.Compute/snapshots.

.PARAMETER TargetDiskName
Name of the new managed disk. Defaults to the source disk name plus a random
suffix. Only valid when a single source disk is copied.

.PARAMETER SnapshotSku
SKU for the snapshot created in the source region. Defaults to the SKU of the
existing incremental snapshots of the source disk, or Standard_LRS when none exist.

.PARAMETER TargetSnapshotSku
SKU for the snapshot copied into the target region. When omitted, the script
reuses the source snapshot SKU. Azure validates SKU availability when it creates
the target snapshot.

.PARAMETER TargetDiskSku
SKU for the new managed disk. Defaults to the SKU of the source disk.

.PARAMETER TenantId
Tenant used in the sign-in hint when no Azure CLI session is found.

.EXAMPLE
.\Copy-AzManagedDisk.ps1

Starts the interactive menus for subscription, virtual machine, disk, and target.

.EXAMPLE
.\Copy-AzManagedDisk.ps1 -SourceSubscriptionId "00000000-0000-0000-0000-000000000000" -SourceResourceGroupName "myRG" -SourceDiskName "hermescloud-osdisk" -TargetRegion "eastus2"

Copies the disk into the same subscription and resource group in East US 2,
reusing the SKU of any existing incremental snapshots.

.EXAMPLE
.\Copy-AzManagedDisk.ps1 -SourceSubscriptionId "00000000-0000-0000-0000-000000000000" -SourceResourceGroupName "myRG" -SourceDiskName "hermescloud-osdisk" -TargetRegion "eastus2" -SnapshotSku "Standard_ZRS" -WhatIf

Shows the operations that would run without changing any resource.

.NOTES
Author: Henrique Rezende
Version: 1.0.0

.LINK
https://github.com/hrezenmsft/scripts
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$SourceSubscriptionId,

    [string]$SourceResourceGroupName,

    [string[]]$SourceDiskName,

    [string]$TargetRegion,

    [string]$TargetSubscriptionId,

    [string]$TargetResourceGroupName,

    [string]$TargetDiskName,

    [ValidateSet("Standard_LRS", "Standard_ZRS")]
    [string]$SnapshotSku,

    [ValidateSet("Standard_LRS", "Standard_ZRS")]
    [string]$TargetSnapshotSku,

    [ValidateSet("Standard_LRS", "StandardSSD_LRS", "StandardSSD_ZRS", "Premium_LRS", "Premium_ZRS", "PremiumV2_LRS", "UltraSSD_LRS")]
    [string]$TargetDiskSku,

    [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($commandName in @("az")) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found."
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    if ([string]::IsNullOrWhiteSpace(($output -join ""))) {
        return $null
    }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

function ConvertFrom-JwtPayload {
    param([Parameter(Mandatory)][string]$AccessToken)

    $segments = $AccessToken.Split('.')
    if ($segments.Count -lt 2) {
        throw "Azure CLI returned an access token with an invalid JWT format."
    }

    $payload = $segments[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { throw "Azure CLI returned an access token with an invalid JWT payload." }
    }

    try {
        return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    }
    catch {
        throw "Could not read the claims in the Azure CLI access token: $($_.Exception.Message)"
    }
}

function Test-AzMfaAccessToken {
    param([string]$Tenant)

    $tokenArguments = @("account", "get-access-token", "--resource", "https://management.azure.com/", "--output", "json")
    if (-not [string]::IsNullOrWhiteSpace($Tenant)) {
        $tokenArguments += @("--tenant", $Tenant)
    }

    $tokenResponse = Invoke-AzJson @tokenArguments
    if ($null -eq $tokenResponse -or [string]::IsNullOrWhiteSpace($tokenResponse.accessToken)) {
        throw "Azure CLI did not return an access token."
    }

    $claims = ConvertFrom-JwtPayload -AccessToken $tokenResponse.accessToken
    return @($claims.amr) -contains "mfa"
}

function Connect-AzCliWithMfa {
    param([string]$Tenant)

    $loginArguments = @("login", "--use-device-code")
    if (-not [string]::IsNullOrWhiteSpace($Tenant)) {
        $loginArguments += @("--tenant", $Tenant)
    }

    Write-Host "Sign in with MFA in the browser to continue." -ForegroundColor Yellow
    $null = & az @loginArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI sign-in failed."
    }
}

$script:SnapshotLocationKeysBySubscription = @{}
function ConvertTo-AzLocationKey {
    param([Parameter(Mandatory)][string]$Location)

    return ($Location -replace '\s', '').ToLowerInvariant()
}

function Get-AzSnapshotLocationKeys {
    param([Parameter(Mandatory)][string]$SubscriptionId)

    if (-not $script:SnapshotLocationKeysBySubscription.ContainsKey($SubscriptionId)) {
        $locations = @(Invoke-AzJson provider show --namespace Microsoft.Compute --subscription $SubscriptionId `
            --query "resourceTypes[?resourceType=='snapshots'].locations[]" --output json)
        $script:SnapshotLocationKeysBySubscription[$SubscriptionId] = @($locations | ForEach-Object { ConvertTo-AzLocationKey -Location $_ })
    }

    return $script:SnapshotLocationKeysBySubscription[$SubscriptionId]
}

$script:IncrementalSnapshotLineage = $null
function Get-SnapshotSkuLineage {
    param([Parameter(Mandatory)][string]$DiskId)

    if ($null -eq $script:IncrementalSnapshotLineage) {
        $script:IncrementalSnapshotLineage = @()
        $snapshotJson = & az snapshot list --query "[?incremental].{sku:sku.name, source:creationData.sourceResourceId}" --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($snapshotJson -join ""))) {
            $script:IncrementalSnapshotLineage = @(($snapshotJson -join [Environment]::NewLine) | ConvertFrom-Json)
        }
    }

    # Resource IDs are compared in PowerShell because JMESPath '==' is case-sensitive.
    $lineage = @($script:IncrementalSnapshotLineage |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.source) -and $_.source -ieq $DiskId })
    if ($lineage.Count -gt 0) {
        Write-Verbose "Matched SKU '$($lineage[0].sku)' from $($lineage.Count) existing incremental snapshot(s) of '$DiskId'."
        return $lineage[0].sku
    }

    Write-Verbose "No existing incremental snapshots found for '$DiskId'. Using 'Standard_LRS'."
    return "Standard_LRS"
}

function Show-AzureMenuHeader {
    Write-Host ""
    Write-Host "Active Azure subscription" -ForegroundColor Yellow
    Write-Host "  $script:ActiveAzureSubscriptionLabel"
}

function Select-MenuItem {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [scriptblock]$LabelExpression,

        [switch]$AllowManualEntry,

        [switch]$Multiple,

        [string]$ManualEntryPrompt = "Enter value",

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxVisible = 20
    )

    if ($Items.Count -eq 0) {
        throw "No choices are available for '$Title'."
    }

    $visibleItems = @($Items | Select-Object -First $MaxVisible)

    while ($true) {
        Show-AzureMenuHeader
        Write-Host $Title -ForegroundColor Cyan
        for ($index = 0; $index -lt $visibleItems.Count; $index++) {
            Write-Host ("[{0}] {1}" -f ($index + 1), (& $LabelExpression $visibleItems[$index]))
        }
        if ($Items.Count -gt $visibleItems.Count) {
            Write-Host ("Showing first {0} of {1}. Use manual entry to target another item." -f $visibleItems.Count, $Items.Count) -ForegroundColor Yellow
        }
        if ($AllowManualEntry) {
            Write-Host "[M] Manually type the value"
        }
        if ($Multiple) {
            Write-Host "[A] Select all"
        }
        Write-Host "[0] Cancel"
        if ($Multiple) {
            Write-Host "Use commas and ranges for multiple choices, for example: 1,3-5"
        }

        $selectionText = (Read-Host "Enter selection").Trim()
        if ($selectionText -eq "0") {
            throw "Selection cancelled."
        }

        if ($AllowManualEntry -and $selectionText -match "^(?i:m|manual)$") {
            $manualValue = (Read-Host $ManualEntryPrompt).Trim()
            if (-not [string]::IsNullOrWhiteSpace($manualValue)) {
                return $manualValue
            }

            Write-Warning "The value cannot be empty."
            continue
        }

        if ($Multiple) {
            if ($selectionText -match "^(?i:a|all)$") {
                return $visibleItems
            }

            $selectedIndexes = @()
            $validSelection = $true
            foreach ($selectionPart in @($selectionText -split ",")) {
                $selectionPart = $selectionPart.Trim()
                if ($selectionPart -match "^(\d+)$") {
                    $rangeStart = [int]$Matches[1]
                    $rangeEnd = $rangeStart
                }
                elseif ($selectionPart -match "^(\d+)\s*-\s*(\d+)$") {
                    $rangeStart = [int]$Matches[1]
                    $rangeEnd = [int]$Matches[2]
                }
                else {
                    $validSelection = $false
                    break
                }

                if ($rangeStart -lt 1 -or $rangeEnd -gt $visibleItems.Count -or $rangeStart -gt $rangeEnd) {
                    $validSelection = $false
                    break
                }
                $selectedIndexes += $rangeStart..$rangeEnd
            }

            if ($validSelection -and $selectedIndexes.Count -gt 0) {
                $zeroBasedIndexes = @($selectedIndexes | Sort-Object -Unique | ForEach-Object { $_ - 1 })
                return @($visibleItems[$zeroBasedIndexes])
            }

            Write-Warning "Enter choices from 1 through $($visibleItems.Count) using commas or ranges, A for all, or 0 to cancel."
            continue
        }

        $selection = 0
        if ([int]::TryParse($selectionText, [ref]$selection) -and $selection -ge 1 -and $selection -le $visibleItems.Count) {
            return $visibleItems[$selection - 1]
        }

        if ($AllowManualEntry) {
            Write-Warning "Enter a number from 1 to $($visibleItems.Count), M for manual entry, or 0 to cancel."
        }
        else {
            Write-Warning "Enter a number from 1 to $($visibleItems.Count), or 0 to cancel."
        }
    }
}

function Write-StepProgress {
    param(
        [Parameter(Mandatory)][int]$Id,
        [int]$ParentId = -1,
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][int]$Step,
        [Parameter(Mandatory)][int]$TotalSteps
    )

    if ($Step -gt $TotalSteps) {
        throw "Progress step $Step cannot exceed total steps $TotalSteps."
    }

    $percentComplete = [math]::Floor(($Step / $TotalSteps) * 100)
    $displayStatus = "$Status ($Target)"
    Write-Progress -Id $Id -ParentId $ParentId -Activity $Activity -Status $displayStatus -PercentComplete $percentComplete
    Write-Host ("[{0}/{1}] {2}" -f $Step, $TotalSteps, $displayStatus) -ForegroundColor Cyan
}

function Write-OperationPreview {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Description,
        [Parameter(Mandatory)][string[]]$Consequences
    )

    Write-Host ""
    Write-Host $Title -ForegroundColor Yellow
    foreach ($line in $Description) { Write-Host "  $line" }
    Write-Warning ($Consequences -join " ")
    Write-Host "Review the operation and respond to the confirmation prompt to continue." -ForegroundColor Yellow
}

$tokenError = $null
try {
    $hasMfaAccessToken = Test-AzMfaAccessToken -Tenant $TenantId
}
catch {
    $hasMfaAccessToken = $false
    $tokenError = $_.Exception.Message
}

if (-not $hasMfaAccessToken) {
    $message = if ([string]::IsNullOrWhiteSpace($tokenError)) {
        "The current Azure CLI access token does not contain the required MFA claim."
    }
    else {
        "Could not validate MFA for the current Azure CLI session: $tokenError"
    }
    Write-Error $message -ErrorAction Continue
    $mfaLoginCommand = "az login --use-device-code"
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $mfaLoginCommand += " --tenant `"$TenantId`""
    }
    Write-Host "To sign in again with MFA, run:" -ForegroundColor Yellow
    Write-Host "  az logout"
    Write-Host "  $mfaLoginCommand"
    $retryLogin = (Read-Host "Redo Azure CLI login with MFA? [Y/N]").Trim()
    if ($retryLogin -notmatch "^(?i:y|yes)$") {
        throw "An Azure CLI access token with an MFA claim is required to continue."
    }

    & az logout 2>$null
    Connect-AzCliWithMfa -Tenant $TenantId
    if (-not (Test-AzMfaAccessToken -Tenant $TenantId)) {
        throw "The refreshed Azure CLI access token does not contain the required MFA claim. Complete an MFA challenge during sign-in and run the script again."
    }
}

$azAccount = Invoke-AzJson account show --output json --only-show-errors
if ($null -eq $azAccount -or [string]::IsNullOrWhiteSpace($azAccount.id)) {
    throw "Azure CLI has no active subscription."
}
$originalSubscriptionId = $azAccount.id
$script:ActiveAzureSubscriptionLabel = "$($azAccount.name) [$($azAccount.id)]"

if ([string]::IsNullOrWhiteSpace($SourceDiskName)) {
    if ([string]::IsNullOrWhiteSpace($SourceSubscriptionId)) {
        $subscriptions = @(Invoke-AzJson account list --output json | Where-Object { $_.state -eq "Enabled" } | Sort-Object name)
        $selectedSubscription = Select-MenuItem -Title "Choose source subscription" -Items $subscriptions `
            -LabelExpression { param($s) "{0} ({1})" -f $s.name, $s.id }
        $SourceSubscriptionId = $selectedSubscription.id
    }
    Invoke-AzJson account set --subscription $SourceSubscriptionId | Out-Null
    $azAccount = Invoke-AzJson account show --output json --only-show-errors
    $script:ActiveAzureSubscriptionLabel = "$($azAccount.name) [$($azAccount.id)]"

    Write-Progress -Id 1 -Activity "Loading source inventory" -Status "Listing virtual machines" -PercentComplete 33
    $allVms = @(Invoke-AzJson vm list --show-details --output json)
    Write-Progress -Id 1 -Activity "Loading source inventory" -Completed

    $vmChoices = @($allVms | Sort-Object resourceGroup, name)
    $vmChoices += [PSCustomObject]@{ id = ""; name = "(unattached disks)"; resourceGroup = ""; location = ""; powerState = "" }

    $selectedVm = Select-MenuItem -Title "Choose virtual machine that owns the disk" -Items $vmChoices -MaxVisible 40 -LabelExpression {
        param($v)
        if ([string]::IsNullOrWhiteSpace($v.id)) { return $v.name }
        "{0} ({1}, {2}, {3})" -f $v.name, $v.resourceGroup, $v.location, $v.powerState
    }

    if ([string]::IsNullOrWhiteSpace($selectedVm.id)) {
        Write-Progress -Id 1 -Activity "Loading source inventory" -Status "Listing unattached disks" -PercentComplete 66
        $diskIds = @(& az resource list --resource-type Microsoft.Compute/disks --query "[].id" --output tsv 2>$null)
        if ($LASTEXITCODE -ne 0 -or $diskIds.Count -eq 0) { throw "No managed disks were found in subscription '$SourceSubscriptionId'." }
        $diskChoices = @(Invoke-AzJson disk show --ids @diskIds --output json | Where-Object { [string]::IsNullOrWhiteSpace($_.managedBy) })
        Write-Progress -Id 1 -Activity "Loading source inventory" -Completed
    }
    else {
        $diskIds = @()
        if ($null -ne $selectedVm.storageProfile.osDisk.managedDisk) {
            $diskIds += $selectedVm.storageProfile.osDisk.managedDisk.id
        }
        foreach ($dataDisk in @($selectedVm.storageProfile.dataDisks)) {
            if ($null -ne $dataDisk.managedDisk) { $diskIds += $dataDisk.managedDisk.id }
        }
        if ($diskIds.Count -eq 0) { throw "'$($selectedVm.name)' has no managed disks." }
        $diskChoices = @(Invoke-AzJson disk show --ids @diskIds --output json)
    }

    if ($diskChoices.Count -eq 0) { throw "No disks were found for '$($selectedVm.name)'." }

    $diskMenuTitle = if ([string]::IsNullOrWhiteSpace($selectedVm.id)) {
        "Choose disks to copy"
    }
    else {
        "Choose disks to copy from $($selectedVm.name)"
    }

    $selectedDisks = @(Select-MenuItem -Title $diskMenuTitle -Items @($diskChoices | Sort-Object name) -MaxVisible 40 -Multiple -LabelExpression {
            param($d)
            $role = if ([string]::IsNullOrWhiteSpace($d.osType)) { "data disk" } else { "OS disk, $($d.osType)" }
            "{0} ({1}, {2} GB, {3})" -f $d.name, $d.sku.name, $d.diskSizeGb, $role
        })

    $sourceDisks = @($selectedDisks)
    $SourceResourceGroupName = $sourceDisks[0].resourceGroup
    $SourceDiskName = @($sourceDisks | ForEach-Object { $_.name })

    if ([string]::IsNullOrWhiteSpace($TargetSubscriptionId)) {
        if (-not (Test-Path variable:subscriptions)) {
            $subscriptions = @(Invoke-AzJson account list --output json | Where-Object { $_.state -eq "Enabled" } | Sort-Object name)
        }
        $selectedTargetSubscription = Select-MenuItem -Title "Choose target subscription" -Items $subscriptions `
            -LabelExpression { param($s) "{0} ({1})" -f $s.name, $s.id }
        $TargetSubscriptionId = $selectedTargetSubscription.id
    }

    if ([string]::IsNullOrWhiteSpace($TargetResourceGroupName)) {
        $resourceGroups = @(Invoke-AzJson group list --subscription $TargetSubscriptionId --output json | Sort-Object name)
        # Assigning directly to the [string] parameter would stringify the whole object.
        $selectedResourceGroup = Select-MenuItem -Title "Choose target resource group" -Items $resourceGroups `
            -AllowManualEntry -ManualEntryPrompt "Enter resource group name" -LabelExpression {
            param($g) "{0} ({1})" -f $g.name, $g.location
        }
        $TargetResourceGroupName = if ($selectedResourceGroup -is [string]) { $selectedResourceGroup } else { $selectedResourceGroup.name }
    }

    if ([string]::IsNullOrWhiteSpace($TargetRegion)) {
        # az account list-locations has no --subscription argument, so it reads the active context.
        $snapshotLocationKeys = Get-AzSnapshotLocationKeys -SubscriptionId $TargetSubscriptionId
        $locations = @(Invoke-AzJson account list-locations --output json |
            Where-Object {
                $_.metadata.regionType -eq "Physical" -and
                $snapshotLocationKeys -contains (ConvertTo-AzLocationKey -Location $_.name)
            } | Sort-Object name)
        $selectedLocation = Select-MenuItem -Title "Choose target region" -Items $locations `
            -LabelExpression {
            param($l) "{0} ({1})" -f $l.name, $l.displayName
        }
        $TargetRegion = $selectedLocation.name
    }
}

foreach ($required in @{ SourceSubscriptionId = $SourceSubscriptionId; SourceResourceGroupName = $SourceResourceGroupName; TargetRegion = $TargetRegion }.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($required.Value)) {
        throw "Parameter -$($required.Key) is required when the script is not run interactively."
    }
}
if ($SourceDiskName.Count -eq 0) {
    throw "Parameter -SourceDiskName is required when the script is not run interactively."
}

if ([string]::IsNullOrWhiteSpace($TargetSubscriptionId)) { $TargetSubscriptionId = $SourceSubscriptionId }
if ([string]::IsNullOrWhiteSpace($TargetResourceGroupName)) { $TargetResourceGroupName = $SourceResourceGroupName }

$targetSnapshotLocationKeys = Get-AzSnapshotLocationKeys -SubscriptionId $TargetSubscriptionId
if ($targetSnapshotLocationKeys -notcontains (ConvertTo-AzLocationKey -Location $TargetRegion)) {
    throw "Target region '$TargetRegion' does not support Microsoft.Compute/snapshots. Select a snapshot-capable target region and run the script again."
}

if ($SourceDiskName.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($TargetDiskName)) {
    throw "-TargetDiskName cannot be used when more than one source disk is copied."
}

Invoke-AzJson account set --subscription $SourceSubscriptionId | Out-Null

if (-not (Test-Path variable:sourceDisks)) {
    $sourceDisks = @()
    foreach ($diskName in $SourceDiskName) {
        $disk = Invoke-AzJson disk show --resource-group $SourceResourceGroupName --name $diskName --output json
        if ($null -eq $disk) {
            throw "Source disk '$diskName' was not found in resource group '$SourceResourceGroupName'."
        }
        $sourceDisks += $disk
    }
}

$copyPlans = @()
$planIndex = 0
foreach ($disk in $sourceDisks) {
    $planIndex++
    Write-Progress -Id 1 -Activity "Preparing copy plan" -Status "Preparing $($disk.name)" -PercentComplete ([math]::Floor(($planIndex / $sourceDisks.Count) * 100))

    # Azure rejects an incremental snapshot whose SKU differs from the disk's existing snapshot lineage.
    $planSnapshotSku = if ([string]::IsNullOrWhiteSpace($SnapshotSku)) { Get-SnapshotSkuLineage -DiskId $disk.id } else { $SnapshotSku }

    $planTargetSnapshotSku = if ([string]::IsNullOrWhiteSpace($TargetSnapshotSku)) { $planSnapshotSku } else { $TargetSnapshotSku }

    $planTargetDiskSku = if ([string]::IsNullOrWhiteSpace($TargetDiskSku)) { $disk.sku.name } else { $TargetDiskSku }

    $randomString = -join ((65..90) + (97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
    $copyPlans += [PSCustomObject]@{
        Disk = $disk
        SnapshotSku = $planSnapshotSku
        TargetSnapshotSku = $planTargetSnapshotSku
        TargetDiskSku = $planTargetDiskSku
        TargetDiskName = if ([string]::IsNullOrWhiteSpace($TargetDiskName)) { "$($disk.name)-copy-$randomString" } else { $TargetDiskName }
        SourceSnapshotName = "$($disk.name)-snapshot-$randomString"
        TargetSnapshotName = "$($disk.name)-snapshot-copy-$randomString"
    }
}
Write-Progress -Id 1 -Activity "Validating copy plan" -Completed

$previewLines = @(
    "Source: $SourceResourceGroupName in subscription $SourceSubscriptionId"
    "Target: $TargetResourceGroupName in $TargetRegion, subscription $TargetSubscriptionId"
    "Temporary snapshots are deleted after every copy attempt."
    "Disks to copy: $($copyPlans.Count)"
)
foreach ($plan in $copyPlans) {
    $previewLines += "  {0} ({1}) to {2} [snapshot {3}, target snapshot {4}, disk {5}]" -f `
        $plan.Disk.name, $plan.Disk.location, $plan.TargetDiskName, $plan.SnapshotSku, $plan.TargetSnapshotSku, $plan.TargetDiskSku
}

Write-OperationPreview -Title "Managed disk copy" -Description $previewLines -Consequences @(
    "This creates billable snapshots and one new managed disk per source disk."
    "Cross-region snapshot copies can take a long time for large disks."
)

if (-not $PSCmdlet.ShouldProcess("$($copyPlans.Count) managed disk(s) in $TargetResourceGroupName", "Copy to $TargetRegion")) {
    return
}

$results = @()
$totalSteps = 3
$diskIndex = 0
$overallActivity = "Copying $($copyPlans.Count) managed disk(s) to $TargetRegion"

try {
    foreach ($plan in $copyPlans) {
        $diskIndex++
        $disk = $plan.Disk
        $diskActivity = "Copying $($disk.name)"
        Write-Progress -Id 1 -Activity $overallActivity -Status "Disk $diskIndex of $($copyPlans.Count): $($disk.name)" -PercentComplete ([math]::Floor((($diskIndex - 1) / $copyPlans.Count) * 100))

        $sourceSnapshot = $null
        $targetSnapshot = $null
        $targetDisk = $null
        $diskStartedAtUTC = (Get-Date).ToUniversalTime()
        $status = "Skipped"
        $errorMessage = ""

        try {
            Invoke-AzJson account set --subscription $SourceSubscriptionId | Out-Null

            Write-StepProgress -Id 2 -ParentId 1 -Activity $diskActivity -Status "Creating source snapshot" -Target $plan.SourceSnapshotName -Step 1 -TotalSteps $totalSteps
            $sourceSnapshot = Invoke-AzJson snapshot create `
                --resource-group $disk.resourceGroup `
                --name $plan.SourceSnapshotName `
                --source $disk.id `
                --location $disk.location `
                --incremental true `
                --sku $plan.SnapshotSku `
                --output json

            Invoke-AzJson account set --subscription $TargetSubscriptionId | Out-Null

            if ($null -ne $sourceSnapshot) {
                Write-StepProgress -Id 2 -ParentId 1 -Activity $diskActivity -Status "Copying snapshot to $TargetRegion" -Target $plan.TargetSnapshotName -Step 2 -TotalSteps $totalSteps
                $targetSnapshot = Invoke-AzJson snapshot create `
                    --resource-group $TargetResourceGroupName `
                    --name $plan.TargetSnapshotName `
                    --source $sourceSnapshot.id `
                    --location $TargetRegion `
                    --incremental true `
                    --sku $plan.TargetSnapshotSku `
                    --copy-start `
                    --output json

                $completionPercent = 0.0
                do {
                    Start-Sleep -Seconds 10
                    $raw = & az snapshot show --name $plan.TargetSnapshotName --resource-group $TargetResourceGroupName --query completionPercent --output tsv 2>$null
                    if (-not [string]::IsNullOrWhiteSpace($raw)) {
                        $completionPercent = [double]::Parse($raw.Trim(), [Globalization.CultureInfo]::InvariantCulture)
                    }
                    Write-Progress -Id 3 -ParentId 2 -Activity "Copying snapshot to $TargetRegion" -Status "$completionPercent% complete" -PercentComplete $completionPercent
                } while ($completionPercent -lt 100)
                Write-Progress -Id 3 -ParentId 2 -Activity "Copying snapshot to $TargetRegion" -Completed
            }

            if ($null -ne $targetSnapshot) {
                Write-StepProgress -Id 2 -ParentId 1 -Activity $diskActivity -Status "Creating target managed disk" -Target $plan.TargetDiskName -Step 3 -TotalSteps $totalSteps
                $diskArguments = @(
                    "disk", "create",
                    "--name", $plan.TargetDiskName,
                    "--resource-group", $TargetResourceGroupName,
                    "--location", $TargetRegion,
                    "--sku", $plan.TargetDiskSku,
                    "--source", $targetSnapshot.id,
                    "--output", "json"
                )
                if (-not [string]::IsNullOrWhiteSpace($disk.osType)) {
                    $diskArguments += @("--os-type", $disk.osType, "--hyper-v-generation", $disk.hyperVGeneration)
                }
                $targetDisk = Invoke-AzJson @diskArguments
                if ($null -ne $targetDisk) { $status = "Success" }
            }
        }
        catch {
            $status = "Failed"
            $errorMessage = $_.Exception.Message
            Write-Warning "Copy of '$($disk.name)' failed: $errorMessage"
        }
        finally {
            Write-Progress -Id 2 -ParentId 1 -Activity $diskActivity -Completed
            foreach ($snapshotToDelete in @(
                    [PSCustomObject]@{ SubscriptionId = $TargetSubscriptionId; ResourceGroupName = $TargetResourceGroupName; Name = $plan.TargetSnapshotName }
                    [PSCustomObject]@{ SubscriptionId = $SourceSubscriptionId; ResourceGroupName = $disk.resourceGroup; Name = $plan.SourceSnapshotName }
                )) {
                Write-Verbose "Deleting temporary snapshot '$($snapshotToDelete.Name)'."
                $deleteOutput = & az snapshot delete --subscription $snapshotToDelete.SubscriptionId --resource-group $snapshotToDelete.ResourceGroupName --name $snapshotToDelete.Name --only-show-errors 2>&1
                if ($LASTEXITCODE -ne 0 -and ($deleteOutput -join [Environment]::NewLine) -notmatch "ResourceNotFound|was not found") {
                    Write-Warning "Could not delete temporary snapshot '$($snapshotToDelete.Name)': $($deleteOutput -join [Environment]::NewLine)"
                }
            }
        }

        $results += [PSCustomObject]@{
            SourceDiskName = $disk.name
            SourceResourceGroupName = $disk.resourceGroup
            SourceRegion = $disk.location
            TargetDiskName = $plan.TargetDiskName
            TargetResourceGroupName = $TargetResourceGroupName
            TargetRegion = $TargetRegion
            TargetSubscriptionId = $TargetSubscriptionId
            SnapshotSku = $plan.SnapshotSku
            TargetDiskSku = $plan.TargetDiskSku
            Status = $status
            Error = $errorMessage
            StartedAtUTC = $diskStartedAtUTC.ToString("o")
            CompletedAtUTC = (Get-Date).ToUniversalTime().ToString("o")
        }
    }
}
finally {
    Write-Progress -Id 1 -Activity $overallActivity -Completed
    if (-not [string]::IsNullOrWhiteSpace($originalSubscriptionId)) {
        & az account set --subscription $originalSubscriptionId 2>$null | Out-Null
    }
}

$results

$failedResults = @($results | Where-Object Status -eq "Failed")
$summaryColor = if ($failedResults.Count -gt 0) { "Red" } else { "Green" }

Write-Host ""
Write-Host "Managed disk copy summary" -ForegroundColor Cyan
Write-Host "  Subscription: $script:ActiveAzureSubscriptionLabel"
Write-Host "  Target: $TargetResourceGroupName in $TargetRegion"
Write-Host "  Processed: $($results.Count)"
Write-Host "  Failed: $($failedResults.Count)" -ForegroundColor $summaryColor
Write-Host "  Temporary snapshots: deleted"
