<#
.SYNOPSIS
Copies an Azure virtual machine to another region without changing the source VM.

.DESCRIPTION
Creates temporary source and target snapshots, copies the OS disk and optionally
data disks to a target region, recreates network interfaces in selected target
subnets, and creates a new VM in a deallocated state. The source VM, disks, NICs,
and public IPs are not changed. Temporary snapshots are deleted after each copy.

Static private IP addresses are retained when available in the selected subnet. If
an address is unavailable, the interactive workflow offers dynamic addressing.
Public IP addresses are recreated; their addresses will change and are reported in
the summary. This script does not migrate VM extensions, availability sets, zones,
dedicated hosts, proximity placement groups, or marketplace plans.

.PARAMETER SourceSubscriptionId
Subscription containing the source VM. Chosen from a menu when omitted.

.PARAMETER SourceResourceGroupName
Resource group containing the source VM. Chosen from a menu when omitted.

.PARAMETER SourceVmName
Source virtual machine name. Chosen from a menu when omitted.

.PARAMETER TargetSubscriptionId
Subscription that receives the VM. Defaults to the source subscription.

.PARAMETER TargetResourceGroupName
Resource group that receives the VM. Chosen from a menu when omitted.

.PARAMETER TargetRegion
Target region. Chosen from snapshot-capable regions when omitted.

.PARAMETER TargetVmName
Name of the new VM. Defaults to the source name plus a random five-character suffix.

.PARAMETER TargetVnetName
Target virtual network. Chosen from a menu when omitted.

.PARAMETER TargetSubnetName
Target subnet. Chosen from a menu when omitted.

.PARAMETER IncludeDataDisks
Copies and attaches data disks. Interactive mode asks when omitted.

.PARAMETER TenantId
Tenant used in the Azure CLI MFA sign-in hint.

.EXAMPLE
.\Move-AzVmToRegion.ps1

.EXAMPLE
.\Move-AzVmToRegion.ps1 -SourceResourceGroupName rg-source -SourceVmName app01 -TargetRegion brazilsouth -IncludeDataDisks

.NOTES
Author: Henrique Rezende
Version: 1.0.1

.LINK
https://github.com/hrezenmsft/scripts
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$SourceSubscriptionId,
    [string]$SourceResourceGroupName,
    [string]$SourceVmName,
    [string]$TargetSubscriptionId,
    [string]$TargetResourceGroupName,
    [string]$TargetRegion,
    [string]$TargetVmName,
    [string]$TargetVnetName,
    [string]$TargetSubnetName,
    [switch]$IncludeDataDisks,
    [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Required command 'az' was not found." }

function Invoke-AzJson {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    if ([string]::IsNullOrWhiteSpace(($output -join ""))) { return $null }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json
}

function Invoke-AzCli {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Show-AzureMenuHeader {
    Write-Host ""; Write-Host "Active Azure subscription" -ForegroundColor Yellow
    Write-Host "  $script:ActiveAzureSubscriptionLabel"
}

function Select-MenuItem {
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$LabelExpression, [switch]$AllowManualEntry,
        [string]$ManualEntryPrompt = "Enter value", [int]$MaxVisible = 30)
    if ($Items.Count -eq 0) { throw "No choices are available for '$Title'." }
    $visibleItems = @($Items | Select-Object -First $MaxVisible)
    while ($true) {
        Show-AzureMenuHeader; Write-Host $Title -ForegroundColor Cyan
        for ($index = 0; $index -lt $visibleItems.Count; $index++) { Write-Host ("[{0}] {1}" -f ($index + 1), (& $LabelExpression $visibleItems[$index])) }
        if ($AllowManualEntry) { Write-Host "[M] Manually type the value" }
        Write-Host "[0] Cancel"
        $selectionText = (Read-Host "Enter selection").Trim()
        if ($selectionText -eq "0") { throw "Selection cancelled." }
        if ($AllowManualEntry -and $selectionText -match "^(?i:m|manual)$") {
            $manualValue = (Read-Host $ManualEntryPrompt).Trim()
            if (-not [string]::IsNullOrWhiteSpace($manualValue)) { return $manualValue }; continue
        }
        $selection = 0
        if ([int]::TryParse($selectionText, [ref]$selection) -and $selection -ge 1 -and $selection -le $visibleItems.Count) { return $visibleItems[$selection - 1] }
        Write-Warning "Enter a number from 1 to $($visibleItems.Count), M for manual entry, or 0 to cancel."
    }
}

function ConvertTo-AzLocationKey { param([Parameter(Mandatory)][string]$Location) return ($Location -replace '\s', '').ToLowerInvariant() }

$script:SnapshotLocationKeysBySubscription = @{}
function Test-AzSnapshotLocation {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Location)
    if (-not $script:SnapshotLocationKeysBySubscription.ContainsKey($SubscriptionId)) {
        $locations = @(Invoke-AzJson provider show --namespace Microsoft.Compute --subscription $SubscriptionId --query "resourceTypes[?resourceType=='snapshots'].locations[]" --output json)
        $script:SnapshotLocationKeysBySubscription[$SubscriptionId] = @($locations | ForEach-Object { ConvertTo-AzLocationKey $_ })
    }
    return $script:SnapshotLocationKeysBySubscription[$SubscriptionId] -contains (ConvertTo-AzLocationKey $Location)
}

function Write-StepProgress {
    param([Parameter(Mandatory)][int]$Step, [Parameter(Mandatory)][int]$TotalSteps, [Parameter(Mandatory)][string]$Status)
    Write-Progress -Id 1 -Activity "Migrating VM to $TargetRegion" -Status "$Status (step $Step of $TotalSteps)" -PercentComplete ([math]::Floor(($Step / $TotalSteps) * 100))
    Write-Host ("[{0}/{1}] {2}" -f $Step, $TotalSteps, $Status) -ForegroundColor Cyan
}

function Get-ResourceGroupFromId { param([Parameter(Mandatory)][string]$ResourceId) if ($ResourceId -match "/resourceGroups/([^/]+)/") { return $Matches[1] }; throw "Could not read a resource group from '$ResourceId'." }
function Get-NameFromId { param([Parameter(Mandatory)][string]$ResourceId) return ($ResourceId -split '/')[-1] }

function New-TemporarySnapshotAndDisk {
    param([Parameter(Mandatory)]$SourceDisk, [Parameter(Mandatory)][string]$TargetDiskName, [Parameter(Mandatory)][bool]$IsOsDisk)
    $suffix = -join ((97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
    $sourceSnapshotName = "$($SourceDisk.name)-migration-source-$suffix"
    $targetSnapshotName = "$($SourceDisk.name)-migration-target-$suffix"
    $sourceSnapshot = $null; $targetSnapshot = $null
    try {
        Invoke-AzCli account set --subscription $SourceSubscriptionId | Out-Null
        $sourceSnapshot = Invoke-AzJson snapshot create --resource-group $SourceDisk.resourceGroup --name $sourceSnapshotName --source $SourceDisk.id --location $SourceDisk.location --incremental true --sku Standard_LRS --output json
        Invoke-AzCli account set --subscription $TargetSubscriptionId | Out-Null
        $targetSnapshot = Invoke-AzJson snapshot create --resource-group $TargetResourceGroupName --name $targetSnapshotName --source $sourceSnapshot.id --location $TargetRegion --incremental true --sku Standard_LRS --copy-start --output json
        do {
            Start-Sleep -Seconds 10
            $percent = & az snapshot show --resource-group $TargetResourceGroupName --name $targetSnapshotName --query completionPercent --output tsv 2>$null
            if ([string]::IsNullOrWhiteSpace($percent)) { $percent = 0 }
            Write-Progress -Id 2 -ParentId 1 -Activity "Copying disk $($SourceDisk.name)" -Status "$percent% complete" -PercentComplete ([double]$percent)
        } while ([double]$percent -lt 100)
        Write-Progress -Id 2 -ParentId 1 -Activity "Copying disk $($SourceDisk.name)" -Completed
        $arguments = @("disk", "create", "--resource-group", $TargetResourceGroupName, "--name", $TargetDiskName, "--location", $TargetRegion, "--source", $targetSnapshot.id, "--sku", $SourceDisk.sku.name, "--output", "json")
        if ($IsOsDisk) { $arguments += @("--os-type", $SourceDisk.osType) }
        return Invoke-AzJson @arguments
    }
    finally {
        foreach ($snapshot in @($targetSnapshot, $sourceSnapshot)) {
            if ($null -eq $snapshot) { continue }
            $snapshotSubscription = if ($snapshot.id -like "*/subscriptions/$TargetSubscriptionId/*") { $TargetSubscriptionId } else { $SourceSubscriptionId }
            $deleteResult = & az snapshot delete --ids $snapshot.id --subscription $snapshotSubscription --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0 -and ($deleteResult -join " ") -notmatch "ResourceNotFound|was not found") { Write-Warning "Could not delete temporary snapshot '$($snapshot.name)': $($deleteResult -join ' ')" }
        }
    }
}

function Test-PrivateIpAvailable {
    param([Parameter(Mandatory)][string]$SubnetId, [Parameter(Mandatory)][string]$IpAddress)
    $vnetId = $SubnetId -replace "/subnets/[^/]+$", ""
    $available = & az network vnet check-ip-address --ids $vnetId --ip-address $IpAddress --query available --output tsv 2>$null
    return $LASTEXITCODE -eq 0 -and $available.Trim() -eq "true"
}

function Test-AzVmExists {
    param([Parameter(Mandatory)][string]$ResourceGroupName, [Parameter(Mandatory)][string]$Name)
    $null = & az vm show --resource-group $ResourceGroupName --name $Name --output none --only-show-errors 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-AzDiskExists {
    param([Parameter(Mandatory)][string]$ResourceGroupName, [Parameter(Mandatory)][string]$Name)
    $null = & az disk show --resource-group $ResourceGroupName --name $Name --output none --only-show-errors 2>$null
    return $LASTEXITCODE -eq 0
}

function New-AzResourceSuffix {
    return -join (1..5 | ForEach-Object { [char](Get-Random -InputObject ((48..57) + (97..122))) })
}

try {
    $null = Invoke-AzJson account get-access-token --resource https://management.azure.com/ --output json
}
catch {
    $loginCommand = "az login --use-device-code"; if ($TenantId) { $loginCommand += " --tenant `"$TenantId`"" }
    throw "No valid Azure CLI session was found. Run '$loginCommand' and complete MFA before running this script."
}

$account = Invoke-AzJson account show --output json
$originalSubscriptionId = $account.id
$script:ActiveAzureSubscriptionLabel = "$($account.name) [$($account.id)]"

try {
    if (-not $SourceSubscriptionId) {
        $subscriptions = @(Invoke-AzJson account list --output json | Where-Object state -eq "Enabled" | Sort-Object name)
        $SourceSubscriptionId = (Select-MenuItem "Choose source subscription" $subscriptions { param($item) "$($item.name) ($($item.id))" }).id
    }
    Invoke-AzCli account set --subscription $SourceSubscriptionId | Out-Null
    if (-not $SourceResourceGroupName) {
        $groups = @(Invoke-AzJson group list --output json | Sort-Object name)
        $selected = Select-MenuItem "Choose source resource group" $groups { param($item) "$($item.name) ($($item.location))" }; $SourceResourceGroupName = $selected.name
    }
    if (-not $SourceVmName) {
        $vms = @(Invoke-AzJson vm list --resource-group $SourceResourceGroupName --output json | Sort-Object name)
        $selected = Select-MenuItem "Choose source virtual machine" $vms { param($item) "$($item.name) ($($item.hardwareProfile.vmSize), $($item.location))" }; $SourceVmName = $selected.name
    }
    $sourceVm = Invoke-AzJson vm show --resource-group $SourceResourceGroupName --name $SourceVmName --output json
    $sourceVmProperties = $sourceVm.PSObject.Properties
    if ($sourceVmProperties.Match("zones").Count -gt 0 -and @($sourceVm.zones).Count -gt 0) { throw "Source VM '$SourceVmName' is zonal. Zonal VM migration is not supported by this script." }
    if (($sourceVmProperties.Match("availabilitySet").Count -gt 0 -and $null -ne $sourceVm.availabilitySet) -or
        ($sourceVmProperties.Match("proximityPlacementGroup").Count -gt 0 -and $null -ne $sourceVm.proximityPlacementGroup) -or
        ($sourceVmProperties.Match("host").Count -gt 0 -and $null -ne $sourceVm.host)) { throw "VM availability sets, proximity placement groups, and dedicated hosts are not migrated. Use Azure Site Recovery or recreate that topology first." }
    if ($sourceVmProperties.Match("plan").Count -gt 0 -and $null -ne $sourceVm.plan) { throw "Marketplace plans are not migrated automatically. Create the target VM with its accepted marketplace plan separately." }
    if ($sourceVmProperties.Match("identity").Count -gt 0 -and $null -ne $sourceVm.identity) { Write-Warning "Managed identities are not assigned to the target VM. Recreate required role assignments after migration." }
    if ($sourceVmProperties.Match("resources").Count -gt 0 -and @($sourceVm.resources).Count -gt 0) { Write-Warning "VM extensions are not migrated. Reinstall required extensions on the target VM after migration." }

    if (-not $TargetSubscriptionId) { $TargetSubscriptionId = $SourceSubscriptionId }
    Invoke-AzCli account set --subscription $TargetSubscriptionId | Out-Null
    if (-not $TargetResourceGroupName) {
        $groups = @(Invoke-AzJson group list --output json | Sort-Object name)
        $selected = Select-MenuItem "Choose target resource group" $groups { param($item) "$($item.name) ($($item.location))" }; $TargetResourceGroupName = $selected.name
    }
    if (-not $TargetRegion) {
        $snapshotLocations = @(Invoke-AzJson provider show --namespace Microsoft.Compute --query "resourceTypes[?resourceType=='snapshots'].locations[]" --output json | ForEach-Object { ConvertTo-AzLocationKey $_ })
        $locations = @(Invoke-AzJson account list-locations --output json | Where-Object { $_.metadata.regionType -eq "Physical" -and $snapshotLocations -contains (ConvertTo-AzLocationKey $_.name) } | Sort-Object name)
        $selected = Select-MenuItem "Choose target region" $locations { param($item) "$($item.displayName) ($($item.name))" }; $TargetRegion = $selected.name
    }
    if (-not (Test-AzSnapshotLocation $TargetSubscriptionId $TargetRegion)) { throw "Target region '$TargetRegion' does not support managed snapshots." }
    $migrationSuffix = New-AzResourceSuffix
    if (-not $TargetVmName) { $TargetVmName = "$SourceVmName-$migrationSuffix" }
    if (Test-AzVmExists $TargetResourceGroupName $TargetVmName) { throw "Target VM '$TargetVmName' already exists." }

    $sourceDataDisks = @($sourceVm.storageProfile.dataDisks)
    if ($sourceDataDisks.Count -gt 0 -and -not $PSBoundParameters.ContainsKey("IncludeDataDisks")) {
        $IncludeDataDisks = (Read-Host "Copy $($sourceDataDisks.Count) data disk(s)? [Y/N]").Trim() -match "^(?i:y|yes)$"
    }
    $sourceDiskIds = @($sourceVm.storageProfile.osDisk.managedDisk.id)
    if ($IncludeDataDisks) { $sourceDiskIds += @($sourceDataDisks | ForEach-Object { $_.managedDisk.id }) }
    foreach ($sourceDiskId in $sourceDiskIds) {
        $targetDiskName = "$(Get-NameFromId $sourceDiskId)-$migrationSuffix"
        if (Test-AzDiskExists $TargetResourceGroupName $targetDiskName) {
            throw "Target disk '$targetDiskName' already exists. Delete the incomplete migration output or specify a different target resource group before retrying."
        }
    }

    $nicPlans = @()
    foreach ($sourceNicReference in @($sourceVm.networkProfile.networkInterfaces)) {
        $sourceNic = Invoke-AzJson network nic show --ids $sourceNicReference.id --output json
        if ($sourceNic.networkSecurityGroup) { Write-Warning "NIC '$($sourceNic.name)' has a network security group that is not migrated. Configure equivalent target-region security rules before starting the VM." }
        $vnets = @(Invoke-AzJson network vnet list --resource-group $TargetResourceGroupName --output json | Where-Object location -eq $TargetRegion | Sort-Object name)
        if ($TargetVnetName) {
            $targetVnet = @($vnets | Where-Object name -eq $TargetVnetName)[0]
            if ($null -eq $targetVnet) { throw "Target VNet '$TargetVnetName' was not found in resource group '$TargetResourceGroupName' and region '$TargetRegion'." }
        }
        else {
            $targetVnet = Select-MenuItem "Choose target VNet for NIC '$($sourceNic.name)'" $vnets { param($item) "$($item.name) ($($item.addressSpace.addressPrefixes -join ', '))" }
        }
        $subnets = @(Invoke-AzJson network vnet subnet list --resource-group $TargetResourceGroupName --vnet-name $targetVnet.name --output json | Sort-Object name)
        if ($TargetSubnetName) {
            $targetSubnet = @($subnets | Where-Object name -eq $TargetSubnetName)[0]
            if ($null -eq $targetSubnet) { throw "Target subnet '$TargetSubnetName' was not found in VNet '$($targetVnet.name)'." }
        }
        else {
            $targetSubnet = Select-MenuItem "Choose target subnet for NIC '$($sourceNic.name)'" $subnets { param($item) "$($item.name) ($($item.addressPrefix))" }
        }
        $ipPlans = @()
        foreach ($sourceIpConfig in @($sourceNic.ipConfigurations)) {
            $privateIp = $sourceIpConfig.privateIPAddress
            $allocation = $sourceIpConfig.privateIPAllocationMethod
            if ($allocation -eq "Static" -and -not (Test-PrivateIpAvailable $targetSubnet.id $privateIp)) {
                Write-Warning "Static IP '$privateIp' for NIC '$($sourceNic.name)' is unavailable in subnet '$($targetSubnet.name)'."
                if ((Read-Host "Use a dynamic IP for this configuration? [Y/N]").Trim() -notmatch "^(?i:y|yes)$") { throw "Migration cancelled because required static IP '$privateIp' is unavailable." }
                $allocation = "Dynamic"; $privateIp = $null
            }
            if ($sourceIpConfig.publicIPAddress) { Write-Warning "NIC '$($sourceNic.name)' has a public IP. A new public IP will be created; the address will change." }
            $ipPlans += [PSCustomObject]@{ Source = $sourceIpConfig; PrivateIp = $privateIp; Allocation = $allocation; SubnetId = $targetSubnet.id; CreatePublicIp = $null -ne $sourceIpConfig.publicIPAddress }
        }
        $isPrimary = $sourceNic.PSObject.Properties.Match("primary").Count -gt 0 -and [bool]$sourceNic.primary
        $nicPlans += [PSCustomObject]@{ Source = $sourceNic; IpPlans = $ipPlans; TargetName = "$($sourceNic.name)-$migrationSuffix"; IsPrimary = $isPrimary }
    }

    $totalSteps = 3 + $(if ($IncludeDataDisks) { $sourceDataDisks.Count } else { 0 }) + $nicPlans.Count
    Write-Host ""; Write-Host "VM regional migration" -ForegroundColor Yellow
    Write-Host "  Source: $SourceVmName in $($sourceVm.location)"; Write-Host "  Target: $TargetVmName in $TargetRegion"
    Write-Host "  Data disks copied: $IncludeDataDisks"; Write-Host "  Temporary snapshots: deleted automatically"
    if (-not $PSCmdlet.ShouldProcess("VM '$TargetVmName' in '$TargetResourceGroupName'", "Create a migrated, deallocated VM in $TargetRegion")) { return }

    $createdDisks = @(); $createdNics = @(); $createdPublicIps = @(); $step = 0
    try {
        $step++; Write-StepProgress $step $totalSteps "Copying OS disk"
        $osDisk = Invoke-AzJson disk show --ids $sourceVm.storageProfile.osDisk.managedDisk.id --output json
        $targetOsDisk = New-TemporarySnapshotAndDisk $osDisk "$($osDisk.name)-$migrationSuffix" $true; $createdDisks += $targetOsDisk
        $targetDataDisks = @()
        if ($IncludeDataDisks) {
            foreach ($dataDiskReference in $sourceDataDisks) {
                $step++; Write-StepProgress $step $totalSteps "Copying data disk $($dataDiskReference.name)"
                $sourceDisk = Invoke-AzJson disk show --ids $dataDiskReference.managedDisk.id --output json
                $targetDisk = New-TemporarySnapshotAndDisk $sourceDisk "$($sourceDisk.name)-$migrationSuffix" $false
                $createdDisks += $targetDisk; $targetDataDisks += [PSCustomObject]@{ Disk = $targetDisk; Lun = $dataDiskReference.lun; Caching = $dataDiskReference.caching }
            }
        }
        foreach ($nicPlan in $nicPlans) {
            $step++; Write-StepProgress $step $totalSteps "Creating network interface $($nicPlan.TargetName)"
            $primaryIpPlan = $nicPlan.IpPlans[0]; $publicIpIdsByConfigName = @{}
            foreach ($ipPlan in $nicPlan.IpPlans | Where-Object CreatePublicIp) {
                $publicIpName = "$($nicPlan.TargetName)-$($ipPlan.Source.name)-pip"
                Invoke-AzCli network public-ip create --resource-group $TargetResourceGroupName --name $publicIpName --location $TargetRegion --sku Standard --allocation-method Static --version IPv4 | Out-Null
                $publicIp = Invoke-AzJson network public-ip show --resource-group $TargetResourceGroupName --name $publicIpName --output json
                $createdPublicIps += $publicIp; $publicIpIdsByConfigName[$ipPlan.Source.name] = $publicIp.id
            }
            $nicArguments = @("network", "nic", "create", "--resource-group", $TargetResourceGroupName, "--name", $nicPlan.TargetName, "--location", $TargetRegion, "--subnet", $primaryIpPlan.SubnetId, "--ip-forwarding", $nicPlan.Source.enableIPForwarding, "--accelerated-networking", $nicPlan.Source.enableAcceleratedNetworking, "--output", "json")
            if ($primaryIpPlan.Allocation -eq "Static") { $nicArguments += @("--private-ip-address", $primaryIpPlan.PrivateIp) }
            if ($publicIpIdsByConfigName.ContainsKey($primaryIpPlan.Source.name)) { $nicArguments += @("--public-ip-address", $publicIpIdsByConfigName[$primaryIpPlan.Source.name]) }
            if ($nicPlan.Source.dnsSettings.dnsServers.Count -gt 0) { $nicArguments += @("--dns-servers") + @($nicPlan.Source.dnsSettings.dnsServers) }
            Invoke-AzCli @nicArguments | Out-Null
            $targetNic = Invoke-AzJson network nic show --resource-group $TargetResourceGroupName --name $nicPlan.TargetName --output json
            $createdNics += $targetNic
            for ($index = 1; $index -lt $nicPlan.IpPlans.Count; $index++) {
                $ipPlan = $nicPlan.IpPlans[$index]; $ipArguments = @("network", "nic", "ip-config", "create", "--resource-group", $TargetResourceGroupName, "--nic-name", $targetNic.name, "--name", $ipPlan.Source.name, "--subnet", $ipPlan.SubnetId)
                if ($ipPlan.Allocation -eq "Static") { $ipArguments += @("--private-ip-address", $ipPlan.PrivateIp) }
                if ($publicIpIdsByConfigName.ContainsKey($ipPlan.Source.name)) { $ipArguments += @("--public-ip-address", $publicIpIdsByConfigName[$ipPlan.Source.name]) }
                Invoke-AzCli @ipArguments | Out-Null
            }
        }
        $step++; Write-StepProgress $step $totalSteps "Creating target VM"
        $primaryNicPlan = @($nicPlans | Where-Object IsPrimary | Select-Object -First 1)[0]
        if ($null -eq $primaryNicPlan) { $primaryNicPlan = $nicPlans[0] }
        $primaryNic = @($createdNics | Where-Object name -eq $primaryNicPlan.TargetName)[0]
        $vmArguments = @("vm", "create", "--resource-group", $TargetResourceGroupName, "--name", $TargetVmName, "--location", $TargetRegion, "--size", $sourceVm.hardwareProfile.vmSize, "--attach-os-disk", $targetOsDisk.id, "--os-type", $osDisk.osType, "--nics")
        $vmArguments += @($primaryNic.id)
        $vmArguments += @($createdNics | Where-Object id -ne $primaryNic.id | ForEach-Object id)
        if ($sourceVm.PSObject.Properties.Match("tags").Count -gt 0 -and $null -ne $sourceVm.tags) {
            $vmArguments += "--tags"
            foreach ($property in $sourceVm.tags.psobject.Properties) { $vmArguments += "$($property.Name)=$($property.Value)" }
        }
        $targetVm = Invoke-AzJson @vmArguments
        $bootDiagnosticsEnabled = $sourceVm.PSObject.Properties.Match("diagnosticsProfile").Count -gt 0 -and
            $null -ne $sourceVm.diagnosticsProfile -and
            $null -ne $sourceVm.diagnosticsProfile.bootDiagnostics -and
            $sourceVm.diagnosticsProfile.bootDiagnostics.enabled
        if ($bootDiagnosticsEnabled) {
            Invoke-AzCli vm boot-diagnostics enable --resource-group $TargetResourceGroupName --name $TargetVmName | Out-Null
        }
        foreach ($dataDisk in $targetDataDisks) { Invoke-AzCli vm disk attach --resource-group $TargetResourceGroupName --vm-name $TargetVmName --name $dataDisk.Disk.id --lun $dataDisk.Lun --caching $dataDisk.Caching | Out-Null }
        $step++; Write-StepProgress $step $totalSteps "Deallocating target VM"
        Invoke-AzCli vm deallocate --resource-group $TargetResourceGroupName --name $TargetVmName | Out-Null
        $publicIpSummary = @($createdPublicIps | ForEach-Object { "$($_.name) ($($_.ipAddress))" }) -join ', '
        $result = [PSCustomObject]@{ Status = "Success"; SourceVmName = $SourceVmName; SourceRegion = $sourceVm.location; TargetVmName = $TargetVmName; TargetResourceGroupName = $TargetResourceGroupName; TargetRegion = $TargetRegion; TargetVmSize = $sourceVm.hardwareProfile.vmSize; PowerState = "deallocated"; NetworkInterfaces = $createdNics.name -join ', '; PublicIps = $publicIpSummary; DataDisksCopied = $targetDataDisks.Count; CompletedAtUTC = (Get-Date).ToUniversalTime().ToString("o") }
        $result
        Write-Host ""; Write-Host "Migration summary" -ForegroundColor Cyan
        $result | Format-List | Out-Host
        if ($createdPublicIps.Count -gt 0) { Write-Warning "New public IPs were created: $publicIpSummary. They differ from the source VM's public IP addresses." }
    }
    catch { throw "VM migration failed. Source VM was not changed. Target resources already created are retained for inspection and can be deleted manually: $($_.Exception.Message)" }
}
finally {
    Write-Progress -Id 1 -Activity "Migrating VM" -Completed
    if ($originalSubscriptionId) { & az account set --subscription $originalSubscriptionId --only-show-errors 2>$null | Out-Null }
}