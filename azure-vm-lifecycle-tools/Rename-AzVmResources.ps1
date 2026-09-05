<#
.SYNOPSIS
Renames an Azure VM resource or managed disks attached to a selected VM.

.DESCRIPTION
Choose one operation for a selected VM: rename its VM resource or rename its
attached managed disks. Azure cannot rename either resource type in place. The
script records the VM configuration, deallocates the VM, and retains NICs and
disks through the required VM recreation. The original VM power state is restored.

The disk operation lets the user select attached OS and data disks to replace
with newly named managed disks. It swaps each replacement onto the selected VM
and deletes the original disk only after its replacement is attached.

The script blocks configurations it cannot safely reproduce, including VM
extensions, marketplace plans, availability sets, zones, dedicated hosts,
proximity placement groups, and managed identities. No temporary resources are
created.

.PARAMETER SubscriptionId
Subscription that contains the VM. Chosen from a menu when omitted.

.PARAMETER ResourceGroupName
Resource group that contains the VM. Chosen from a menu when omitted.

.PARAMETER VmName
Current VM name. Chosen from a menu when omitted.

.PARAMETER NewVmName
New VM name. Required when -RenameVm is selected and prompted for when omitted.

.PARAMETER RenameVm
Renames the VM resource. When no rename switches are supplied, the interactive
workflow offers VM-only or disk-only rename options.

.PARAMETER RenameDisks
Creates newly named replacement OS and data disks. Disk-only mode keeps the VM
resource intact and swaps only the selected attached disks.

.PARAMETER DiskName
One or more attached OS or data disk names to rename. Chosen from a menu when
omitted with -RenameDisks.

.PARAMETER TenantId
Tenant used in the Azure CLI MFA sign-in hint.

.EXAMPLE
.\Rename-AzVmResources.ps1

.EXAMPLE
.\Rename-AzVmResources.ps1 -ResourceGroupName MyRG -VmName oldvm -NewVmName newvm -RenameVm

.EXAMPLE
.\Rename-AzVmResources.ps1 -ResourceGroupName MyRG -VmName app01 -RenameDisks

.EXAMPLE
.\Rename-AzVmResources.ps1 -ResourceGroupName MyRG -VmName app01 -RenameDisks -DiskName app01-osdisk,app01-data01

.NOTES
Author: Henrique Rezende
Version: 1.0.1

.LINK
https://github.com/hrezenmsft/scripts
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$VmName,
    [ValidatePattern("^[a-zA-Z0-9][a-zA-Z0-9-_]{0,63}$")]
    [string]$NewVmName,
    [switch]$RenameVm,
    [switch]$RenameDisks,
    [string[]]$DiskName,
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
    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function Show-AzureMenuHeader {
    Write-Host ""; Write-Host "Active Azure subscription" -ForegroundColor Yellow
    Write-Host "  $script:ActiveAzureSubscriptionLabel"
}

function Select-MenuItem {
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][object[]]$Items, [Parameter(Mandatory)][scriptblock]$LabelExpression)
    if ($Items.Count -eq 0) { throw "No choices are available for '$Title'." }
    while ($true) {
        Show-AzureMenuHeader; Write-Host $Title -ForegroundColor Cyan
        for ($index = 0; $index -lt $Items.Count; $index++) { Write-Host ("[{0}] {1}" -f ($index + 1), (& $LabelExpression $Items[$index])) }
        Write-Host "[0] Cancel"
        $selection = 0; $selectionText = (Read-Host "Enter selection").Trim()
        if ($selectionText -eq "0") { throw "Selection cancelled." }
        if ([int]::TryParse($selectionText, [ref]$selection) -and $selection -ge 1 -and $selection -le $Items.Count) { return $Items[$selection - 1] }
        Write-Warning "Enter a number from 1 through $($Items.Count), or 0 to cancel."
    }
}

function Select-RenameOperation {
    while ($true) {
        Show-AzureMenuHeader
        Write-Host "Choose rename operation" -ForegroundColor Cyan
        Write-Host "[1] Rename VM resource only"
        Write-Host "[2] Rename OS and data disks only"
        Write-Host "[0] Cancel"
        switch ((Read-Host "Enter selection").Trim()) {
            "1" { return [PSCustomObject]@{ RenameVm = $true; RenameDisks = $false } }
            "2" { return [PSCustomObject]@{ RenameVm = $false; RenameDisks = $true } }
            "0" { throw "Selection cancelled." }
            default { Write-Warning "Enter 1, 2, or 0 to cancel." }
        }
    }
}

function Select-AttachedDiskPlans {
    param([Parameter(Mandatory)][object[]]$DiskPlans)

    while ($true) {
        Show-AzureMenuHeader
        Write-Host "Choose attached disks to rename" -ForegroundColor Cyan
        for ($index = 0; $index -lt $DiskPlans.Count; $index++) {
            $diskPlan = $DiskPlans[$index]
            $role = if ($diskPlan.IsOsDisk) { "OS disk" } else { "data disk, LUN $($diskPlan.Lun)" }
            Write-Host ("[{0}] {1} ({2})" -f ($index + 1), $diskPlan.SourceDisk.name, $role)
        }
        Write-Host "[A] All attached disks"
        Write-Host "[0] Cancel"
        $selectionText = (Read-Host "Enter selections, for example 1,3-4").Trim()
        if ($selectionText -eq "0") { throw "Selection cancelled." }
        if ($selectionText -match "^(?i:a|all)$") { return $DiskPlans }

        $selectedIndexes = @()
        $validSelection = $true
        foreach ($selectionPart in @($selectionText -split ',')) {
            $selectionPart = $selectionPart.Trim()
            if ($selectionPart -match "^(\d+)$") { $start = [int]$Matches[1]; $end = $start }
            elseif ($selectionPart -match "^(\d+)\s*-\s*(\d+)$") { $start = [int]$Matches[1]; $end = [int]$Matches[2] }
            else { $validSelection = $false; break }
            if ($start -lt 1 -or $end -gt $DiskPlans.Count -or $start -gt $end) { $validSelection = $false; break }
            $selectedIndexes += $start..$end
        }
        if ($validSelection -and $selectedIndexes.Count -gt 0) {
            return @($selectedIndexes | Sort-Object -Unique | ForEach-Object { $DiskPlans[$_ - 1] })
        }
        Write-Warning "Enter disk choices from 1 through $($DiskPlans.Count), A for all, or 0 to cancel."
    }
}

function Test-AzVmExists {
    param([Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$Name)
    $null = & az vm show --resource-group $ResourceGroup --name $Name --output none --only-show-errors 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-AzDiskExists {
    param([Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$Name)
    $null = & az disk show --resource-group $ResourceGroup --name $Name --output none --only-show-errors 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-AzDataDiskAttachment {
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][int]$Lun
    )

    $attachedDiskId = & az vm show --resource-group $ResourceGroupName --name $VmName `
        --query "storageProfile.dataDisks[?lun==``$Lun``].managedDisk.id | [0]" --output tsv --only-show-errors 2>$null
    return $LASTEXITCODE -eq 0 -and ([string]$attachedDiskId).Trim() -ieq $DiskId
}

function Read-NewDiskName {
    param([Parameter(Mandatory)][string]$CurrentName, [Parameter(Mandatory)][string]$DefaultName)

    while ($true) {
        $newName = (Read-Host "New name for disk '$CurrentName' [$DefaultName]").Trim()
        if ([string]::IsNullOrWhiteSpace($newName)) { $newName = $DefaultName }
        if ($newName -notmatch "^[a-zA-Z0-9][a-zA-Z0-9-_]{0,79}$") {
            Write-Warning "Disk names must contain 1 to 80 letters, numbers, hyphens, or underscores."
            continue
        }
        if (Test-AzDiskExists -ResourceGroup $ResourceGroupName -Name $newName) {
            Write-Warning "A disk named '$newName' already exists in resource group '$ResourceGroupName'."
            continue
        }
        return $newName
    }
}

function New-RenamedDisk {
    param([Parameter(Mandatory)]$SourceDisk, [Parameter(Mandatory)][string]$NewName)

    return Invoke-AzJson disk create --resource-group $ResourceGroupName --name $NewName `
        --location $SourceDisk.location --source $SourceDisk.id --sku $SourceDisk.sku.name --output json
}

function Write-StepProgress {
    param([Parameter(Mandatory)][int]$Step, [Parameter(Mandatory)][int]$TotalSteps, [Parameter(Mandatory)][string]$Status)
    $activity = if ($RenameDisks) { "Renaming selected disks on VM '$VmName'" } else { "Renaming VM '$VmName' to '$NewVmName'" }
    Write-Progress -Id 1 -Activity $activity -Status "$Status (step $Step of $TotalSteps)" -PercentComplete ([math]::Floor(($Step / $TotalSteps) * 100))
    Write-Host ("[{0}/{1}] {2}" -f $Step, $TotalSteps, $Status) -ForegroundColor Cyan
}

try { $null = Invoke-AzJson account get-access-token --resource https://management.azure.com/ --output json }
catch {
    $loginCommand = "az login --use-device-code"; if ($TenantId) { $loginCommand += " --tenant `"$TenantId`"" }
    throw "No valid Azure CLI session was found. Run '$loginCommand' and complete MFA before running this script."
}

$account = Invoke-AzJson account show --output json
$originalSubscriptionId = $account.id
$script:ActiveAzureSubscriptionLabel = "$($account.name) [$($account.id)]"

try {
    if (-not $SubscriptionId) {
        $subscriptions = @(Invoke-AzJson account list --output json | Where-Object state -eq "Enabled" | Sort-Object name)
        $SubscriptionId = (Select-MenuItem "Choose subscription" $subscriptions { param($item) "$($item.name) ($($item.id))" }).id
    }
    Invoke-AzCli account set --subscription $SubscriptionId | Out-Null
    if (-not $ResourceGroupName) {
        $groups = @(Invoke-AzJson group list --output json | Sort-Object name)
        $ResourceGroupName = (Select-MenuItem "Choose VM resource group" $groups { param($item) "$($item.name) ($($item.location))" }).name
    }
    if (-not $VmName) {
        $vms = @(Invoke-AzJson vm list --resource-group $ResourceGroupName --output json | Sort-Object name)
        $VmName = (Select-MenuItem "Choose VM to rename" $vms { param($item) "$($item.name) ($($item.hardwareProfile.vmSize), $($item.location))" }).name
    }
    if ($NewVmName -and $RenameDisks) { throw "-NewVmName cannot be used with -RenameDisks. Run VM and disk renames as separate operations." }
    if ($NewVmName) { $RenameVm = $true }
    if (-not $PSBoundParameters.ContainsKey("RenameVm") -and -not $PSBoundParameters.ContainsKey("RenameDisks")) {
        $operation = Select-RenameOperation
        $RenameVm = $operation.RenameVm
        $RenameDisks = $operation.RenameDisks
    }
    if ($RenameVm -and $RenameDisks) { throw "-RenameVm and -RenameDisks cannot be used together. Run them as separate operations." }
    if (-not $RenameVm -and -not $RenameDisks) { throw "Select either -RenameVm or -RenameDisks." }
    $requestedDiskNames = @($DiskName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($requestedDiskNames.Count -gt 0 -and -not $RenameDisks) { throw "-DiskName can only be used with -RenameDisks." }
    if ($RenameVm -and -not $NewVmName) {
        $NewVmName = (Read-Host "Enter new VM name").Trim()
        if ([string]::IsNullOrWhiteSpace($NewVmName)) { throw "New VM name cannot be empty." }
    }
    if ($RenameVm) {
        if ($NewVmName -notmatch "^[a-zA-Z0-9][a-zA-Z0-9-_]{0,63}$") { throw "New VM name '$NewVmName' is invalid. Use 1 to 64 letters, numbers, hyphens, or underscores." }
        if ($NewVmName -ieq $VmName) { throw "The new VM name must differ from '$VmName'." }
        if (Test-AzVmExists $ResourceGroupName $NewVmName) { throw "A VM named '$NewVmName' already exists in resource group '$ResourceGroupName'." }
    }
    else {
        $NewVmName = $VmName
    }

    $sourceVm = Invoke-AzJson vm show --resource-group $ResourceGroupName --name $VmName --output json
    $vmProperties = $sourceVm.PSObject.Properties
    if (($vmProperties.Match("zones").Count -gt 0 -and @($sourceVm.zones).Count -gt 0) -or
        ($vmProperties.Match("availabilitySet").Count -gt 0 -and $null -ne $sourceVm.availabilitySet) -or
        ($vmProperties.Match("proximityPlacementGroup").Count -gt 0 -and $null -ne $sourceVm.proximityPlacementGroup) -or
        ($vmProperties.Match("host").Count -gt 0 -and $null -ne $sourceVm.host)) { throw "Zonal VMs, availability sets, proximity placement groups, and dedicated hosts are not supported by this rename script." }
    if ($vmProperties.Match("plan").Count -gt 0 -and $null -ne $sourceVm.plan) { throw "Marketplace plans are not supported by this rename script." }
    if ($vmProperties.Match("identity").Count -gt 0 -and $null -ne $sourceVm.identity) { throw "Managed identities are not supported by this rename script because a renamed VM receives a different principal ID." }
    if ($vmProperties.Match("resources").Count -gt 0 -and @($sourceVm.resources).Count -gt 0) { throw "VM extensions are not supported by this rename script. Remove or reinstall them after a manual rename." }

    $statusVm = Invoke-AzJson vm show --resource-group $ResourceGroupName --name $VmName --show-details --output json
    $wasRunning = $statusVm.powerState -eq "VM running"
    $networkInterfaces = @($sourceVm.networkProfile.networkInterfaces)
    $dataDisks = @($sourceVm.storageProfile.dataDisks)
    $osDisk = $sourceVm.storageProfile.osDisk
    if ($null -eq $osDisk.managedDisk) { throw "Only managed-disk VMs are supported." }

    $sourceOsDisk = Invoke-AzJson disk show --ids $osDisk.managedDisk.id --output json
    $sourceDataDiskPlans = @()
    foreach ($dataDisk in $dataDisks) {
        $sourceDataDiskPlans += [PSCustomObject]@{
            SourceDisk = Invoke-AzJson disk show --ids $dataDisk.managedDisk.id --output json
            Lun = $dataDisk.lun
            Caching = $dataDisk.caching
        }
    }
    $attachedDiskPlans = @(
        [PSCustomObject]@{ SourceDisk = $sourceOsDisk; IsOsDisk = $true; Lun = $null; Caching = $osDisk.caching }
    )
    $attachedDiskPlans += $sourceDataDiskPlans | ForEach-Object {
        [PSCustomObject]@{ SourceDisk = $_.SourceDisk; IsOsDisk = $false; Lun = $_.Lun; Caching = $_.Caching }
    }

    $diskRenamePlans = @()
    if ($RenameDisks) {
        # Explicit disk names support noninteractive runs; otherwise show attached OS/data disks.
        if ($requestedDiskNames.Count -gt 0) {
            $selectedDiskPlans = @($attachedDiskPlans | Where-Object { $requestedDiskNames -contains $_.SourceDisk.name })
            $unmatchedDiskNames = @($requestedDiskNames | Where-Object { $_ -notin @($selectedDiskPlans | ForEach-Object { $_.SourceDisk.name }) })
            if ($unmatchedDiskNames.Count -gt 0) { throw "These disk names are not attached to VM '$VmName': $($unmatchedDiskNames -join ', ')." }
        }
        else {
            $selectedDiskPlans = Select-AttachedDiskPlans -DiskPlans $attachedDiskPlans
        }
        foreach ($selectedDiskPlan in $selectedDiskPlans) {
            $diskRenamePlans += [PSCustomObject]@{
                SourceDisk = $selectedDiskPlan.SourceDisk
                NewName = Read-NewDiskName -CurrentName $selectedDiskPlan.SourceDisk.name -DefaultName "$($selectedDiskPlan.SourceDisk.name)-renamed"
                IsOsDisk = $selectedDiskPlan.IsOsDisk
                Lun = $selectedDiskPlan.Lun
                Caching = $selectedDiskPlan.Caching
            }
        }
        $duplicateDiskNames = @($diskRenamePlans.NewName | Group-Object | Where-Object Count -gt 1)
        if ($duplicateDiskNames.Count -gt 0) { throw "Each renamed disk must have a unique name. Duplicate names: $($duplicateDiskNames.Name -join ', ')." }
    }

    Write-Host ""; Write-Host "VM rename plan" -ForegroundColor Yellow
    Write-Host "  Rename VM resource: $RenameVm"; Write-Host "  Current VM: $VmName"; Write-Host "  Resulting VM: $NewVmName"; Write-Host "  Resource group: $ResourceGroupName"; Write-Host "  Original power state: $($statusVm.powerState)"
    Write-Host "  Rename OS and data disks: $RenameDisks"
    if ($RenameVm) {
        Write-Warning "The VM will be unavailable while Azure deletes and recreates its VM resource. Disks and NICs will be detached and retained."
    }
    else {
        Write-Warning "The VM will be deallocated while selected disks are swapped. Its VM resource, NICs, and unselected disks remain unchanged."
    }
    $operationDescription = if ($RenameVm) { "Delete and recreate it as '$NewVmName'" } else { "Swap $($diskRenamePlans.Count) selected managed disk(s)" }
    if (-not $PSCmdlet.ShouldProcess("VM '$VmName'", $operationDescription)) { return }

    if ($RenameDisks) {
        $totalSteps = (3 * $diskRenamePlans.Count) + 3
        $step = 0
        $createdRenamedDisks = @()
        try {
            $step++; Write-StepProgress $step $totalSteps "Deallocating VM"
            Invoke-AzCli vm deallocate --resource-group $ResourceGroupName --name $VmName | Out-Null
            foreach ($diskRenamePlan in $diskRenamePlans) {
                $step++; Write-StepProgress $step $totalSteps "Creating replacement disk $($diskRenamePlan.NewName)"
                $createdRenamedDisks += New-RenamedDisk -SourceDisk $diskRenamePlan.SourceDisk -NewName $diskRenamePlan.NewName
            }
            foreach ($diskRenamePlan in $diskRenamePlans) {
                $replacementDisk = @($createdRenamedDisks | Where-Object name -eq $diskRenamePlan.NewName)[0]
                if ($diskRenamePlan.IsOsDisk) {
                    $step++; Write-StepProgress $step $totalSteps "Swapping OS disk $($diskRenamePlan.SourceDisk.name)"
                    Invoke-AzCli vm update --resource-group $ResourceGroupName --name $VmName --os-disk $replacementDisk.id | Out-Null
                }
                else {
                    $step++; Write-StepProgress $step $totalSteps "Swapping data disk $($diskRenamePlan.SourceDisk.name) at LUN $($diskRenamePlan.Lun)"
                    Invoke-AzCli vm disk detach --resource-group $ResourceGroupName --vm-name $VmName --name $diskRenamePlan.SourceDisk.name | Out-Null
                    Invoke-AzCli vm disk attach --resource-group $ResourceGroupName --vm-name $VmName --name $replacementDisk.id --lun $diskRenamePlan.Lun --caching $diskRenamePlan.Caching | Out-Null
                    # Do not delete the original disk until Azure reports the required LUN mapping.
                    if (-not (Test-AzDataDiskAttachment -VmName $VmName -DiskId $replacementDisk.id -Lun $diskRenamePlan.Lun)) {
                        throw "Replacement disk '$($replacementDisk.name)' was not attached to VM '$VmName' at required LUN $($diskRenamePlan.Lun). The original disk '$($diskRenamePlan.SourceDisk.name)' was retained."
                    }
                }
                $step++; Write-StepProgress $step $totalSteps "Deleting original disk $($diskRenamePlan.SourceDisk.name)"
                Invoke-AzCli disk delete --ids $diskRenamePlan.SourceDisk.id --yes | Out-Null
            }
            $step++; Write-StepProgress $step $totalSteps "Restoring VM power state"
            if ($wasRunning) { Invoke-AzCli vm start --resource-group $ResourceGroupName --name $VmName | Out-Null }
            $step++; Write-StepProgress $step $totalSteps "Verifying disk changes"
            $updatedVm = Invoke-AzJson vm show --resource-group $ResourceGroupName --name $VmName --show-details --output json
            $result = [PSCustomObject]@{ Status = "Success"; VmName = $VmName; ResourceGroupName = $ResourceGroupName; Location = $updatedVm.location; PowerState = $updatedVm.powerState; RenamedDisks = @($diskRenamePlans | ForEach-Object { "$($_.SourceDisk.name) -> $($_.NewName)" }) -join '; '; CompletedAtUTC = (Get-Date).ToUniversalTime().ToString("o") }
            $result
            Write-Host ""; Write-Host "Disk rename summary" -ForegroundColor Cyan; $result | Format-List | Out-Host
            return
        }
        finally {
            foreach ($createdDisk in $createdRenamedDisks) {
                $managedBy = & az disk show --ids $createdDisk.id --query "managedBy" --output tsv --only-show-errors 2>$null
                if ($LASTEXITCODE -eq 0 -and [string]::IsNullOrWhiteSpace($managedBy)) {
                    & az disk delete --ids $createdDisk.id --yes --only-show-errors 2>$null | Out-Null
                }
            }
        }
    }

    $totalSteps = 6
    $step = 0
    $createdRenamedDisks = @()
    $originalDisksDeleted = $false
    try {
    if ($RenameDisks) {
        foreach ($diskRenamePlan in $diskRenamePlans) {
            $step++; Write-StepProgress $step $totalSteps "Creating replacement disk $($diskRenamePlan.NewName)"
            $createdRenamedDisks += New-RenamedDisk -SourceDisk $diskRenamePlan.SourceDisk -NewName $diskRenamePlan.NewName
        }
    }
    $step++; Write-StepProgress $step $totalSteps "Deallocating original VM"
    Invoke-AzCli vm deallocate --resource-group $ResourceGroupName --name $VmName | Out-Null

    $step++; Write-StepProgress $step $totalSteps "Protecting disks and NICs from deletion"
    $updateArguments = @("vm", "update", "--resource-group", $ResourceGroupName, "--name", $VmName, "--set", "storageProfile.osDisk.deleteOption=Detach")
    foreach ($index in 0..($dataDisks.Count - 1)) { if ($dataDisks.Count -gt 0) { $updateArguments += "storageProfile.dataDisks[$index].deleteOption=Detach" } }
    foreach ($index in 0..($networkInterfaces.Count - 1)) { $updateArguments += "networkProfile.networkInterfaces[$index].deleteOption=Detach" }
    Invoke-AzCli @updateArguments | Out-Null

    $step++; Write-StepProgress $step $totalSteps "Deleting original VM resource"
    Invoke-AzCli vm delete --resource-group $ResourceGroupName --name $VmName --yes | Out-Null
    do { Start-Sleep -Seconds 5 } while (Test-AzVmExists $ResourceGroupName $VmName)

    $step++; Write-StepProgress $step $totalSteps "Creating renamed VM"
    $targetOsDiskId = if ($RenameDisks) { @($createdRenamedDisks | Where-Object name -eq $diskRenamePlans[0].NewName)[0].id } else { $osDisk.managedDisk.id }
    $vmArguments = @("vm", "create", "--resource-group", $ResourceGroupName, "--name", $NewVmName, "--location", $sourceVm.location, "--size", $sourceVm.hardwareProfile.vmSize, "--attach-os-disk", $targetOsDiskId, "--os-type", $osDisk.osType, "--nics")
    $vmArguments += @($networkInterfaces | ForEach-Object id)
    if ($sourceDataDiskPlans.Count -gt 0) {
        $vmArguments += "--attach-data-disks"
        $vmArguments += @($sourceDataDiskPlans | Sort-Object Lun | ForEach-Object { $_.SourceDisk.id })
    }
    if ($vmProperties.Match("tags").Count -gt 0 -and $null -ne $sourceVm.tags) { $vmArguments += "--tags"; foreach ($tag in $sourceVm.tags.PSObject.Properties) { $vmArguments += "$($tag.Name)=$($tag.Value)" } }
    Invoke-AzJson @vmArguments | Out-Null

    $bootDiagnosticsEnabled = $vmProperties.Match("diagnosticsProfile").Count -gt 0 -and $null -ne $sourceVm.diagnosticsProfile -and $null -ne $sourceVm.diagnosticsProfile.bootDiagnostics -and $sourceVm.diagnosticsProfile.bootDiagnostics.enabled
    if ($bootDiagnosticsEnabled) { Invoke-AzCli vm boot-diagnostics enable --resource-group $ResourceGroupName --name $NewVmName | Out-Null }
    if ($RenameDisks) {
        $step++; Write-StepProgress $step $totalSteps "Deleting original OS and data disks"
        foreach ($diskRenamePlan in $diskRenamePlans) {
            Invoke-AzCli disk delete --ids $diskRenamePlan.SourceDisk.id --yes | Out-Null
        }
        $originalDisksDeleted = $true
    }
    $step++; Write-StepProgress $step $totalSteps "Restoring VM power state"
    if ($wasRunning) { Invoke-AzCli vm start --resource-group $ResourceGroupName --name $NewVmName | Out-Null }
    $step++; Write-StepProgress $step $totalSteps "Verifying renamed VM"
    $newVm = Invoke-AzJson vm show --resource-group $ResourceGroupName --name $NewVmName --show-details --output json

    $resultOsDisk = if ($RenameDisks) { $diskRenamePlans[0].NewName } else { $osDisk.name }
    $resultDataDisks = if ($RenameDisks) {
        @($diskRenamePlans | Where-Object { -not $_.IsOsDisk } | ForEach-Object NewName) -join ', '
    }
    else {
        @($sourceDataDiskPlans | ForEach-Object { $_.SourceDisk.name }) -join ', '
    }
    $actionsCompleted = @(
        "Deallocated '$VmName'"
        "Set disk and NIC delete options to Detach"
        "Deleted VM resource '$VmName'"
        "Created VM resource '$NewVmName'"
        "Attached OS disk '$resultOsDisk'"
    )
    if ($sourceDataDiskPlans.Count -gt 0) { $actionsCompleted += "Attached $($sourceDataDiskPlans.Count) data disk(s)" }
    if ($RenameDisks) { $actionsCompleted += "Created renamed OS and data disks; deleted original disks after attachment" }
    if ($wasRunning) { $actionsCompleted += "Restored the running power state" }

    $result = [PSCustomObject]@{ Status = "Success"; PreviousVmName = $VmName; NewVmName = $NewVmName; ResourceGroupName = $ResourceGroupName; Location = $newVm.location; VmSize = $newVm.hardwareProfile.vmSize; PowerState = $newVm.powerState; OsDisk = $resultOsDisk; DataDisks = $resultDataDisks; NetworkInterfaces = @($networkInterfaces | ForEach-Object { $_.id }) -join ', '; ActionsCompleted = $actionsCompleted -join '; '; CompletedAtUTC = (Get-Date).ToUniversalTime().ToString("o") }
    $result
    Write-Host ""; Write-Host "VM rename summary" -ForegroundColor Cyan; $result | Format-List | Out-Host
    }
    finally {
        if (-not $originalDisksDeleted) {
            foreach ($createdDisk in $createdRenamedDisks) {
                $managedBy = & az disk show --ids $createdDisk.id --query "managedBy" --output tsv --only-show-errors 2>$null
                if ($LASTEXITCODE -eq 0 -and [string]::IsNullOrWhiteSpace($managedBy)) {
                    & az disk delete --ids $createdDisk.id --yes --only-show-errors 2>$null | Out-Null
                }
            }
        }
    }
}
finally {
    Write-Progress -Id 1 -Activity "Renaming VM" -Completed
    if ($originalSubscriptionId) { & az account set --subscription $originalSubscriptionId --only-show-errors 2>$null | Out-Null }
}