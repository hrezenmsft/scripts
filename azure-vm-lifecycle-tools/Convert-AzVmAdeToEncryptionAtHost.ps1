<#
.SYNOPSIS
Prepares or migrates Azure Disk Encryption VMs to encryption at host.

.DESCRIPTION
Selects one or more VMs from a resource group, detects the operating system and
ADE volume state, and performs one of two guarded stages. Prepare starts ADE
decryption for supported scenarios. Migrate upload-copies affected managed disks
to remove persistent ADE metadata, deletes and recreates the VM with the same
name and NICs, and enables encryption at host.

Interactive VM discovery lists only VMs with the Windows or Linux ADE extension.
The menu and result objects include affected disks, ADE states, extension details,
Disk Encryption Key (DEK) secret references, Key Vault resource IDs, and Key
Encryption Key (KEK) references. The script does not retrieve secret or key values.

Prepare and Migrate print numbered step-status lines and update a PowerShell
progress display around long-running Azure operations.

Windows OS-only and all-volume ADE scenarios are supported. Linux data-only ADE
is supported. Linux VMs whose OS disk is ADE-encrypted require a fresh VM and
application or file migration and are reported as unsupported by this script.

Migration causes downtime and replaces the VM resource. Backups and guest-level
decryption verification through Azure Run Command is mandatory. Existing non-ADE
VM extensions cannot be recreated because protected settings cannot be exported,
so interactive runs require confirmation and unattended runs require
-AllowExtensionLoss. It never deletes original managed disks. An active Azure CLI
session, Az PowerShell modules, AzCopy, and permission to run commands on the
selected VMs are required.

.PARAMETER ResourceGroupName
Resource group containing the source VMs. When omitted, an interactive menu is shown.

.PARAMETER VmName
One or more VM names. When omitted, an interactive multiple-selection menu is shown.

.PARAMETER Stage
Prepare starts ADE decryption. Migrate performs disk copying and VM replacement.
When omitted, an interactive menu is shown.

.PARAMETER VolumeType
ADE scope override for -ResumeAfterAdeRemoval only. Normal Prepare and Migrate
runs always use Auto and detect the scope from the ADE extension.

.PARAMETER SubscriptionId
Optional Azure subscription name or ID. Defaults to the active Azure CLI subscription.

.PARAMETER TenantId
Optional tenant ID included in sign-in guidance when authentication is missing.

.PARAMETER AllowExtensionLoss
Allows unattended migration when non-ADE VM extensions exist. Interactive runs
offer an in-place confirmation. Those extensions must be reinstalled afterward.

.PARAMETER ResumeAfterAdeRemoval
Resumes Migrate for an explicitly named, fully decrypted VM after a prior attempt
removed its ADE extension. Requires an explicit OS, Data, or All volume type.

.PARAMETER ResumeFailedReplacement
Retries a failed encryption-at-host replacement allocation with its unchanged
original VM size.

.PARAMETER SasDurationSeconds
Lifetime of source and target disk SAS URLs. Defaults to 86400 seconds.

.PARAMETER DiscoveryThrottleLimit
Maximum concurrent VM inspections during interactive discovery on PowerShell 7.
Defaults to 8. Windows PowerShell 5.1 discovery remains sequential.

.PARAMETER OutputPath
Optional CSV destination for result objects, including ADE disk, extension,
Key Vault, DEK reference, and KEK reference details.

.EXAMPLE
.\Convert-AzVmAdeToEncryptionAtHost.ps1

Uses menus to select the resource group, stage, and one or more VMs. ADE scope
is detected automatically.

.EXAMPLE
.\Convert-AzVmAdeToEncryptionAtHost.ps1 -ResourceGroupName rg-prod -VmName app01,app02 -Stage Prepare

Starts ADE decryption for the supported selected VMs.

.EXAMPLE
.\Convert-AzVmAdeToEncryptionAtHost.ps1 -ResourceGroupName rg-prod -VmName app01 -Stage Migrate -WhatIf

Checks Azure and guest decryption state, then shows the destructive migration operation.

.NOTES
Author: Henrique Rezende
Version: 1.0.0

.LINK
https://github.com/hrezenmsft/azure-vm-lifecycle-tools

.LINK
https://learn.microsoft.com/azure/virtual-machines/disk-encryption-migrate
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$ResourceGroupName,

    [string[]]$VmName,

    [ValidateSet("Prepare", "Migrate")]
    [string]$Stage,

    [ValidateSet("Auto", "OS", "Data", "All")]
    [string]$VolumeType = "Auto",

    [string]$SubscriptionId,

    [string]$TenantId,

    [switch]$AllowExtensionLoss,

    [switch]$ResumeAfterAdeRemoval,

    [switch]$ResumeFailedReplacement,

    [ValidateRange(3600, 86400)]
    [int]$SasDurationSeconds = 86400,

    [ValidateRange(1, 32)]
    [int]$DiscoveryThrottleLimit = 8,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:InteractiveSelection = @("ResourceGroupName", "VmName", "Stage") |
    Where-Object { -not $PSBoundParameters.ContainsKey($_) } |
    Select-Object -First 1
$script:ComputeSkusByLocation = @{}
$script:EncryptionAtHostFeatureState = $null

Write-Host ""
Write-Host "IMPORTANT: A TESTED BACKUP OF EVERY TARGET VM IS HIGHLY RECOMMENDED" -ForegroundColor Red
Write-Warning "This tool changes disk encryption and can delete and recreate VM resources. Failures, interruption, or incorrect recovery can result in permanent data loss. Verify that each target VM has a current, tested backup before continuing."
Write-Host ""

function Get-ResourceGroupFromId {
    param([Parameter(Mandatory)][string]$ResourceId)

    if ($ResourceId -match "/resourceGroups/([^/]+)/") {
        return $Matches[1]
    }
    throw "Could not parse a resource group from '$ResourceId'."
}

function Get-ComputeVmSku {
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$VmSize
    )

    if (-not $script:ComputeSkusByLocation.ContainsKey($Location)) {
        $script:ComputeSkusByLocation[$Location] = @(Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
            Where-Object ResourceType -eq "virtualMachines")
    }
    return $script:ComputeSkusByLocation[$Location] | Where-Object Name -eq $VmSize | Select-Object -First 1
}

function Assert-EncryptionAtHostFeatureEnabled {
    if ($null -eq $script:EncryptionAtHostFeatureState) {
        $script:EncryptionAtHostFeatureState = [string](Get-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost -ErrorAction Stop).RegistrationState
    }
    if ($script:EncryptionAtHostFeatureState -ne "Registered") {
        throw "Subscription feature 'Microsoft.Compute/EncryptionAtHost' is '$script:EncryptionAtHostFeatureState'. Register it and refresh Microsoft.Compute before migration."
    }
}

function Write-StepProgress {
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][int]$Step,
        [Parameter(Mandatory)][int]$TotalSteps
    )

    $percentComplete = [math]::Floor(($Step / $TotalSteps) * 100)
    $displayStatus = "$Status ($VmName)"
    Write-Progress -Id $Id -Activity $Activity -Status $displayStatus -PercentComplete $percentComplete
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

function Assert-LocalPrerequisites {
    $issues = [System.Collections.Generic.List[string]]::new()
    if ($PSVersionTable.PSVersion -lt [version]"5.1") {
        $issues.Add("PowerShell 5.1 or later is required. Resolve: install current PowerShell from https://aka.ms/powershell-release and rerun the script in that version.")
    }

    $requiredModules = @("Az.Accounts", "Az.Compute", "Az.Network", "Az.Resources")
    $missingModules = @($requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
    if ($missingModules.Count -gt 0) {
        $issues.Add("Missing Azure PowerShell modules: $($missingModules -join ', '). Resolve: run 'Install-Module $($missingModules -join ',') -Scope CurrentUser', then restart PowerShell.")
    }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        $issues.Add("Azure CLI ('az') was not found on PATH. Resolve: install it with 'winget install Microsoft.AzureCLI', restart PowerShell, then run 'az login'.")
    }
    else {
        $null = & az version --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            $issues.Add("Azure CLI was found but could not run successfully. Resolve: repair or reinstall it with 'winget install Microsoft.AzureCLI --force', restart PowerShell, then run 'az login'.")
        }
    }
    if (-not (Get-Command azcopy -ErrorAction SilentlyContinue)) {
        $issues.Add("AzCopy ('azcopy') was not found on PATH. Resolve: install it with 'winget install Microsoft.AzCopy.10', then restart PowerShell.")
    }
    else {
        $null = & azcopy --version 2>$null
        if ($LASTEXITCODE -ne 0) {
            $issues.Add("AzCopy was found but could not run successfully. Resolve: repair or reinstall it with 'winget install Microsoft.AzCopy.10 --force', then restart PowerShell.")
        }
    }

    $requiredCommands = @(
        "Connect-AzAccount", "Get-AzContext", "Set-AzContext", "Invoke-AzRestMethod", "Get-AzProviderFeature", "Get-AzResourceGroup", "Get-AzVM", "Get-AzVMExtension",
        "Get-AzVMDiskEncryptionStatus", "Disable-AzVMDiskEncryption", "Remove-AzVMDiskEncryptionExtension", "Invoke-AzVMRunCommand",
        "Get-AzDisk", "New-AzDiskConfig", "New-AzDisk", "Remove-AzDisk", "Grant-AzDiskAccess",
        "Revoke-AzDiskAccess", "Get-AzComputeResourceSku", "Get-AzNetworkInterface", "Stop-AzVM", "Update-AzVM", "Remove-AzVM",
        "New-AzVMConfig", "Set-AzVMSecurityProfile", "Set-AzVMOSDisk", "Add-AzVMDataDisk",
        "Add-AzVMNetworkInterface", "Set-AzVMBootDiagnostic", "Set-AzVMPlan", "New-AzVM"
    )
    $missingCommands = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missingCommands.Count -gt 0) {
        $issues.Add("Missing or outdated Az PowerShell commands: $($missingCommands -join ', '). Resolve: run 'Update-Module Az.Accounts,Az.Compute,Az.Network,Az.Resources' or install the modules listed above.")
    }

    if ($issues.Count -gt 0) {
        Write-Host "Local prerequisite check failed" -ForegroundColor Red
        foreach ($issue in $issues) { Write-Warning $issue }
        throw "Resolve the local prerequisite issues above, restart PowerShell if required, and rerun the script."
    }

    Write-Host "Local prerequisite check passed: Azure CLI, AzCopy, and required Az PowerShell modules are available." -ForegroundColor Green
}

function Test-AzureActionAllowed {
    param(
        [Parameter(Mandatory)][object[]]$PermissionBlocks,
        [Parameter(Mandatory)][string]$Action
    )

    foreach ($permissionBlock in $PermissionBlocks) {
        $allowed = $false
        foreach ($pattern in @($permissionBlock.Actions)) {
            if ($Action -like [string]$pattern) { $allowed = $true; break }
        }
        if (-not $allowed) { continue }

        $excluded = $false
        foreach ($pattern in @($permissionBlock.NotActions)) {
            if ($Action -like [string]$pattern) { $excluded = $true; break }
        }
        if (-not $excluded) { return $true }
    }
    return $false
}

function Assert-AzurePermissions {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string[]]$RequiredActions,
        [Parameter(Mandatory)][string]$Purpose
    )

    $requestPath = "$Scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    try {
        if ($script:AzureCliAuthenticated) {
            $requestUri = "https://management.azure.com$requestPath"
            $responseContent = @(& az rest --method get --url $requestUri --output json --only-show-errors) -join [Environment]::NewLine
            if ($LASTEXITCODE -ne 0) { throw "Azure CLI permission request failed with exit code $LASTEXITCODE." }
        }
        else {
            $response = Invoke-AzRestMethod -Path $requestPath -Method GET -Paginate -WhatIf:$false -ErrorAction Stop
            $responseContent = $response.Content
        }
        $permissionBlocks = @((($responseContent | ConvertFrom-Json -ErrorAction Stop).value))
    }
    catch {
        throw "Azure permission preflight could not read effective permissions at '$Scope'. Ask an Azure administrator to grant permission to read Microsoft.Authorization/permissions at this scope, or to verify your role assignment. Details: $($_.Exception.Message)"
    }
    if ($permissionBlocks.Count -eq 0) {
        throw "Azure permission preflight returned no effective permissions at '$Scope'. Ask an Azure administrator to assign an appropriate role at this scope."
    }

    $missingActions = @($RequiredActions | Select-Object -Unique | Where-Object { -not (Test-AzureActionAllowed -PermissionBlocks $permissionBlocks -Action $_) })
    if ($missingActions.Count -gt 0) {
        Write-Host "Azure permission check failed for $Purpose" -ForegroundColor Red
        Write-Host "  Scope: $Scope"
        Write-Host "  Missing actions:" -ForegroundColor Yellow
        foreach ($action in $missingActions) { Write-Host "    - $action" -ForegroundColor Yellow }
        Write-Warning "Ask an Azure administrator to assign a role containing the missing actions at the scope above. Contributor is sufficient but broad; a custom least-privilege role containing the listed actions is preferred. Role assignments can take several minutes to propagate."
        throw "The signed-in identity does not have all Azure permissions required for $Purpose."
    }

    Write-Host "Azure permission check passed for $Purpose at '$Scope'." -ForegroundColor Green
}

function Get-RequiredAzureActions {
    param([Parameter(Mandatory)][ValidateSet("Prepare", "Migrate")][string]$Stage)

    $actions = @(
        "Microsoft.Resources/subscriptions/resourceGroups/read"
        "Microsoft.Compute/virtualMachines/read"
        "Microsoft.Compute/virtualMachines/instanceView/read"
        "Microsoft.Compute/virtualMachines/extensions/read"
        "Microsoft.Compute/disks/read"
        "Microsoft.Compute/skus/read"
        "Microsoft.Network/networkInterfaces/read"
    )
    if ($Stage -eq "Prepare") {
        return $actions + @(
            "Microsoft.Compute/virtualMachines/extensions/write"
        )
    }
    return $actions + @(
        "Microsoft.Features/providers/features/read"
        "Microsoft.Compute/virtualMachines/write"
        "Microsoft.Compute/virtualMachines/delete"
        "Microsoft.Compute/virtualMachines/deallocate/action"
        "Microsoft.Compute/virtualMachines/runCommand/action"
        "Microsoft.Compute/virtualMachines/extensions/write"
        "Microsoft.Compute/virtualMachines/extensions/delete"
        "Microsoft.Compute/disks/write"
        "Microsoft.Compute/disks/delete"
        "Microsoft.Compute/disks/beginGetAccess/action"
        "Microsoft.Compute/disks/endGetAccess/action"
    )
}

function Show-SubscriptionHeader {
    Write-Host ""
    Write-Host "Active Azure subscription" -ForegroundColor Yellow
    Write-Host "  $script:ActiveSubscriptionLabel"
}

function Select-ResourceGroup {
    $resourceGroups = @(Get-AzResourceGroup -ErrorAction Stop | Sort-Object ResourceGroupName)
    if ($resourceGroups.Count -eq 0) { throw "No resource groups were found." }

    while ($true) {
        Show-SubscriptionHeader
        Write-Host "Choose resource group" -ForegroundColor Cyan
        for ($index = 0; $index -lt $resourceGroups.Count; $index++) {
            Write-Host ("[{0}] {1} ({2})" -f ($index + 1), $resourceGroups[$index].ResourceGroupName, $resourceGroups[$index].Location)
        }
        Write-Host "[M] Manually enter a resource group"
        Write-Host "[0] Cancel"
        $selection = (Read-Host "Enter selection").Trim()
        if ($selection -eq "0") { throw "Selection cancelled." }
        if ($selection -match "^(?i:m|manual)$") {
            $manualName = (Read-Host "Resource group name").Trim()
            if ($manualName) { return $manualName }
        }
        $number = 0
        if ([int]::TryParse($selection, [ref]$number) -and $number -ge 1 -and $number -le $resourceGroups.Count) {
            return $resourceGroups[$number - 1].ResourceGroupName
        }
        Write-Warning "Enter a listed number, M, or 0."
    }
}

function ConvertFrom-SelectionList {
    param(
        [Parameter(Mandatory)][string]$Selection,
        [Parameter(Mandatory)][int]$Maximum
    )

    if ($Selection -match "^(?i:a|all)$") { return @(1..$Maximum) }
    $selected = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($part in $Selection.Split(",")) {
        $value = $part.Trim()
        if ($value -match "^(\d+)-(\d+)$") {
            $first = [int]$Matches[1]
            $last = [int]$Matches[2]
            if ($first -gt $last) { $temporary = $first; $first = $last; $last = $temporary }
            foreach ($number in $first..$last) { if ($number -ge 1 -and $number -le $Maximum) { $null = $selected.Add($number) } }
        }
        else {
            $number = 0
            if ([int]::TryParse($value, [ref]$number) -and $number -ge 1 -and $number -le $Maximum) { $null = $selected.Add($number) }
            else { throw "Invalid VM selection '$value'." }
        }
    }
    return @($selected | Sort-Object)
}

function Get-OptionalPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function New-MigrationResult {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Details,
        [Parameter(Mandatory)][datetime]$StartedAtUtc,
        [AllowNull()][object]$Scenario,
        [AllowNull()][object]$AdeDetails,
        [AllowNull()][string]$RequestedVolumeType,
        [AllowNull()][string]$OsType,
        [AllowNull()][string]$ResultVolumeType,
        [AllowNull()][string]$AdeExtension
    )

    [PSCustomObject]@{
        ResourceGroupName = $ResourceGroupName
        VmName = $VmName
        OsType = if ($PSBoundParameters.ContainsKey("OsType")) { $OsType } elseif ($Scenario) { $Scenario.OsType } else { $null }
        VolumeType = if ($PSBoundParameters.ContainsKey("ResultVolumeType")) { $ResultVolumeType } elseif ($Scenario) { $Scenario.VolumeType } else { $RequestedVolumeType }
        AdeDisks = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "Disks"
        AdeDiskEncryptionDetails = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "DiskEncryptionDetails"
        DiskEncryptionKeyUrls = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "DiskEncryptionKeyUrls"
        DiskEncryptionKeyVaultIds = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "DiskEncryptionKeyVaultIds"
        DiskKeyEncryptionKeyUrls = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "DiskKeyEncryptionKeyUrls"
        DiskKekVaultIds = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "DiskKekVaultIds"
        AdeOsVolumeState = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "OsVolumeState"
        AdeDataVolumeState = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "DataVolumeState"
        AdeExtension = if ($PSBoundParameters.ContainsKey("AdeExtension")) { $AdeExtension } elseif ($AdeDetails) { "$($AdeDetails.ExtensionType) $($AdeDetails.ExtensionVersion)" } else { $null }
        KeyVaultUrl = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "KeyVaultUrl"
        KeyVaultResourceId = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "KeyVaultResourceId"
        KeyEncryptionAlgorithm = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "KeyEncryptionAlgorithm"
        KeyEncryptionKeyUrl = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "KeyEncryptionKeyUrl"
        KekVaultResourceId = Get-OptionalPropertyValue -InputObject $AdeDetails -Name "KekVaultResourceId"
        Stage = $Stage
        Status = $Status
        Details = $Details
        StartedAtUtc = $StartedAtUtc.ToString("o")
        CompletedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Get-AdeExtension {
    param([Parameter(Mandatory)][object]$Vm)

    return Get-AzVMExtension -ResourceGroupName $Vm.ResourceGroupName -VMName $Vm.Name -ErrorAction Stop |
        Where-Object ExtensionType -in @("AzureDiskEncryption", "AzureDiskEncryptionForLinux") |
        Select-Object -First 1
}

function Get-AdeVmDetails {
    param([Parameter(Mandatory)][object]$Vm)

    $adeExtension = Get-AdeExtension -Vm $Vm
    if (-not $adeExtension) { return $null }

    $encryptionStatus = Get-AzVMDiskEncryptionStatus -ResourceGroupName $Vm.ResourceGroupName -VMName $Vm.Name -ErrorAction SilentlyContinue
    $settings = if ($adeExtension.PublicSettings) { $adeExtension.PublicSettings | ConvertFrom-Json -ErrorAction Stop } else { $null }
    $configuredVolumeType = [string](Get-OptionalPropertyValue -InputObject $settings -Name "VolumeType")
    $osState = [string](Get-OptionalPropertyValue -InputObject $encryptionStatus -Name "OsVolumeEncrypted")
    $dataState = [string](Get-OptionalPropertyValue -InputObject $encryptionStatus -Name "DataVolumesEncrypted")
    $effectiveVolumeType = if ($configuredVolumeType -in @("OS", "Data", "All")) {
        $configuredVolumeType
    }
    elseif ((Test-EncryptedState $osState) -and (Test-EncryptedState $dataState)) { "All" }
    elseif (Test-EncryptedState $osState) { "OS" }
    elseif (Test-EncryptedState $dataState) { "Data" }
    else { "Unknown" }

    $diskReferences = [System.Collections.Generic.List[object]]::new()
    if ($effectiveVolumeType -in @("OS", "All", "Unknown")) {
        $diskReferences.Add([PSCustomObject]@{ Role = "OS"; Name = $Vm.StorageProfile.OsDisk.Name; Id = $Vm.StorageProfile.OsDisk.ManagedDisk.Id; Lun = $null })
    }
    if ($effectiveVolumeType -in @("Data", "All", "Unknown")) {
        foreach ($dataDisk in @($Vm.StorageProfile.DataDisks | Sort-Object Lun)) {
            $diskReferences.Add([PSCustomObject]@{ Role = "Data"; Name = $dataDisk.Name; Id = $dataDisk.ManagedDisk.Id; Lun = $dataDisk.Lun })
        }
    }

    $diskDetails = [System.Collections.Generic.List[string]]::new()
    $diskKeyDetails = [System.Collections.Generic.List[string]]::new()
    $diskEncryptionKeyUrls = [System.Collections.Generic.List[string]]::new()
    $diskEncryptionKeyVaultIds = [System.Collections.Generic.List[string]]::new()
    $diskKeyEncryptionKeyUrls = [System.Collections.Generic.List[string]]::new()
    $diskKekVaultIds = [System.Collections.Generic.List[string]]::new()
    foreach ($diskReference in $diskReferences) {
        $lunLabel = if ($null -ne $diskReference.Lun) { "(LUN $($diskReference.Lun))" } else { "" }
        $diskDetails.Add("$($diskReference.Role):$($diskReference.Name)$lunLabel")
        $diskResourceGroup = Get-ResourceGroupFromId -ResourceId $diskReference.Id
        $managedDisk = Get-AzDisk -ResourceGroupName $diskResourceGroup -DiskName $diskReference.Name -ErrorAction Stop
        $encryptionSettings = @(if ($managedDisk.EncryptionSettingsCollection) { $managedDisk.EncryptionSettingsCollection.EncryptionSettings })
        $encryptionSetting = if ($encryptionSettings.Count -gt 0) { $encryptionSettings[0] } else { $null }
        $diskEncryptionKey = Get-OptionalPropertyValue -InputObject $encryptionSetting -Name "DiskEncryptionKey"
        $keyEncryptionKey = Get-OptionalPropertyValue -InputObject $encryptionSetting -Name "KeyEncryptionKey"
        $dekUrl = [string](Get-OptionalPropertyValue -InputObject $diskEncryptionKey -Name "SecretUrl")
        $dekVault = Get-OptionalPropertyValue -InputObject $diskEncryptionKey -Name "SourceVault"
        $dekVaultId = [string](Get-OptionalPropertyValue -InputObject $dekVault -Name "Id")
        $diskKekUrl = [string](Get-OptionalPropertyValue -InputObject $keyEncryptionKey -Name "KeyUrl")
        $diskKekVault = Get-OptionalPropertyValue -InputObject $keyEncryptionKey -Name "SourceVault"
        $diskKekVaultId = [string](Get-OptionalPropertyValue -InputObject $diskKekVault -Name "Id")
        if ($dekUrl) { $diskEncryptionKeyUrls.Add($dekUrl) }
        if ($dekVaultId) { $diskEncryptionKeyVaultIds.Add($dekVaultId) }
        if ($diskKekUrl) { $diskKeyEncryptionKeyUrls.Add($diskKekUrl) }
        if ($diskKekVaultId) { $diskKekVaultIds.Add($diskKekVaultId) }
        if ($encryptionSetting) {
            $diskKeyDetails.Add("$($diskReference.Role):$($diskReference.Name) [DEK Vault: $(if ($dekVaultId) { $dekVaultId } else { 'None' }); DEK: $(if ($dekUrl) { $dekUrl } else { 'None' }); KEK Vault: $(if ($diskKekVaultId) { $diskKekVaultId } else { 'None' }); KEK: $(if ($diskKekUrl) { $diskKekUrl } else { 'None' })]")
        }
        else {
            $diskKeyDetails.Add("$($diskReference.Role):$($diskReference.Name) [disk-level ADE key metadata unavailable]")
        }
    }

    [PSCustomObject]@{
        ExtensionName = $adeExtension.Name
        ExtensionType = $adeExtension.ExtensionType
        ExtensionVersion = $adeExtension.TypeHandlerVersion
        EncryptionOperation = [string](Get-OptionalPropertyValue -InputObject $settings -Name "EncryptionOperation")
        VolumeType = $effectiveVolumeType
        OsVolumeState = $osState
        DataVolumeState = $dataState
        Disks = @($diskDetails) -join ";"
        DiskEncryptionDetails = @($diskKeyDetails) -join " | "
        DiskEncryptionKeyUrls = @($diskEncryptionKeyUrls | Select-Object -Unique) -join ";"
        DiskEncryptionKeyVaultIds = @($diskEncryptionKeyVaultIds | Select-Object -Unique) -join ";"
        DiskKeyEncryptionKeyUrls = @($diskKeyEncryptionKeyUrls | Select-Object -Unique) -join ";"
        DiskKekVaultIds = @($diskKekVaultIds | Select-Object -Unique) -join ";"
        KeyVaultUrl = [string](Get-OptionalPropertyValue -InputObject $settings -Name "KeyVaultURL")
        KeyVaultResourceId = [string](Get-OptionalPropertyValue -InputObject $settings -Name "KeyVaultResourceId")
        KeyEncryptionAlgorithm = [string](Get-OptionalPropertyValue -InputObject $settings -Name "KeyEncryptionAlgorithm")
        KeyEncryptionKeyUrl = [string](Get-OptionalPropertyValue -InputObject $settings -Name "KeyEncryptionKeyURL")
        KekVaultResourceId = [string](Get-OptionalPropertyValue -InputObject $settings -Name "KekVaultResourceId")
        EncryptionStatus = $encryptionStatus
    }
}

function Get-AdeRemovalRecoveryDetails {
    param(
        [Parameter(Mandatory)][object]$Vm,
        [Parameter(Mandatory)][ValidateSet("OS", "Data", "All")][string]$VolumeType
    )

    $encryptionStatus = Get-AzVMDiskEncryptionStatus -ResourceGroupName $Vm.ResourceGroupName -VMName $Vm.Name -ErrorAction Stop
    $osState = [string]$encryptionStatus.OsVolumeEncrypted
    $dataState = [string]$encryptionStatus.DataVolumesEncrypted
    if ($VolumeType -in @("OS", "All") -and $osState -ne "NotEncrypted") {
        throw "Cannot resume VM '$($Vm.Name)': OS volume state is '$osState', not 'NotEncrypted'."
    }
    if ($VolumeType -in @("Data", "All") -and $dataState -notin @("NotEncrypted", "NoDiskFound")) {
        throw "Cannot resume VM '$($Vm.Name)': data volume state is '$dataState', not fully decrypted."
    }

    $diskDetails = [System.Collections.Generic.List[string]]::new()
    if ($VolumeType -in @("OS", "All")) { $diskDetails.Add("OS:$($Vm.StorageProfile.OsDisk.Name)") }
    if ($VolumeType -in @("Data", "All")) {
        foreach ($dataDisk in @($Vm.StorageProfile.DataDisks | Sort-Object Lun)) {
            $diskDetails.Add("Data:$($dataDisk.Name)(LUN $($dataDisk.Lun))")
        }
    }

    [PSCustomObject]@{
        ExtensionName = $null
        ExtensionType = "RemovedBeforeMigration"
        ExtensionVersion = $null
        EncryptionOperation = "ResumeAfterAdeRemoval"
        VolumeType = $VolumeType
        OsVolumeState = $osState
        DataVolumeState = $dataState
        Disks = @($diskDetails) -join ";"
        DiskEncryptionDetails = "ADE extension was removed by a prior interrupted migration."
        DiskEncryptionKeyUrls = $null
        DiskEncryptionKeyVaultIds = $null
        DiskKeyEncryptionKeyUrls = $null
        DiskKekVaultIds = $null
        KeyVaultUrl = $null
        KeyVaultResourceId = $null
        KeyEncryptionAlgorithm = $null
        KeyEncryptionKeyUrl = $null
        KekVaultResourceId = $null
        EncryptionStatus = $encryptionStatus
    }
}

function Get-UnsupportedAdeScenarioReason {
    param(
        [Parameter(Mandatory)][string]$OsType,
        [Parameter(Mandatory)][string]$VolumeType
    )

    if ($OsType -eq "Linux" -and $VolumeType -in @("OS", "All")) {
        return "Linux ADE OS disks cannot be decrypted in place. Deploy a new VM with encryption at host and migrate the workload."
    }
    if ($OsType -eq "Windows" -and $VolumeType -eq "Data") {
        return "Windows data-only ADE is not a supported migration pattern. Windows ADE is expected to protect the OS disk or all disks."
    }
    return $null
}

function Export-AdeDiscoveryReport {
    param(
        [Parameter(Mandatory)][object[]]$DiscoveredVirtualMachines,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    $defaultPath = Join-Path (Get-Location).ProviderPath "ADE-VM-Discovery-$ResourceGroupName-$timestamp.csv"
    $enteredPath = (Read-Host "CSV path [$defaultPath]").Trim()
    $reportPath = if ($enteredPath) { $enteredPath } else { $defaultPath }
    $resolvedReportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($reportPath)
    $reportDirectory = Split-Path -Parent $resolvedReportPath
    if (-not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
        throw "The report directory '$reportDirectory' does not exist."
    }

    $report = foreach ($entry in $DiscoveredVirtualMachines) {
        [PSCustomObject]@{
            SubscriptionId = [string]$script:ActiveSubscriptionId
            SubscriptionName = [string]$script:ActiveSubscriptionName
            ResourceGroupName = $entry.Vm.ResourceGroupName
            VmName = $entry.Vm.Name
            Location = $entry.Vm.Location
            VmSize = $entry.Vm.HardwareProfile.VmSize
            OsType = $entry.Vm.StorageProfile.OsDisk.OsType
            AdeVolumeType = $entry.Ade.VolumeType
            MigrationSupported = -not [bool]$entry.UnsupportedReason
            UnsupportedReason = $entry.UnsupportedReason
            AdeOsVolumeState = $entry.Ade.OsVolumeState
            AdeDataVolumeState = $entry.Ade.DataVolumeState
            AdeExtensionName = $entry.Ade.ExtensionName
            AdeExtensionType = $entry.Ade.ExtensionType
            AdeExtensionVersion = $entry.Ade.ExtensionVersion
            AdeEncryptionOperation = $entry.Ade.EncryptionOperation
            AdeDisks = $entry.Ade.Disks
            AdeDiskEncryptionDetails = $entry.Ade.DiskEncryptionDetails
            KeyVaultUrl = $entry.Ade.KeyVaultUrl
            KeyVaultResourceId = $entry.Ade.KeyVaultResourceId
            KeyEncryptionAlgorithm = $entry.Ade.KeyEncryptionAlgorithm
            KeyEncryptionKeyUrl = $entry.Ade.KeyEncryptionKeyUrl
            KekVaultResourceId = $entry.Ade.KekVaultResourceId
            DiskEncryptionKeyUrls = $entry.Ade.DiskEncryptionKeyUrls
            DiskEncryptionKeyVaultIds = $entry.Ade.DiskEncryptionKeyVaultIds
            DiskKeyEncryptionKeyUrls = $entry.Ade.DiskKeyEncryptionKeyUrls
            DiskKekVaultIds = $entry.Ade.DiskKekVaultIds
            DiscoveredAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }
    }
    $report | Export-Csv -LiteralPath $resolvedReportPath -NoTypeInformation -Encoding UTF8
    Write-Host "ADE discovery report exported: $resolvedReportPath" -ForegroundColor Green
}

function Select-VirtualMachines {
    param([Parameter(Mandatory)][string]$ResourceGroupName)

    Write-Host "Discovering ADE-enabled VMs in '$ResourceGroupName'..." -ForegroundColor Cyan
    $resourceGroupVirtualMachines = @(Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Sort-Object Name)
    if ($resourceGroupVirtualMachines.Count -eq 0) { throw "No VMs were found in resource group '$ResourceGroupName'." }

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $DiscoveryThrottleLimit -gt 1) {
        Write-Host "Inspecting up to $DiscoveryThrottleLimit VMs concurrently..." -ForegroundColor Cyan
        $activeAzContext = Get-AzContext -ErrorAction Stop
        $functionDefinitions = @{}
        foreach ($functionName in @("Get-ResourceGroupFromId", "Get-OptionalPropertyValue", "Test-EncryptedState", "Get-AdeExtension", "Get-AdeVmDetails", "Get-UnsupportedAdeScenarioReason")) {
            $functionDefinitions[$functionName] = (Get-Item -Path "Function:\$functionName" -ErrorAction Stop).ScriptBlock.ToString()
        }
        $discoveryResults = @($resourceGroupVirtualMachines | ForEach-Object -Parallel {
            $ErrorActionPreference = "Stop"
            Set-StrictMode -Version Latest
            $vm = $_
            try {
                Set-AzContext -Context $using:activeAzContext -Scope Process -ErrorAction Stop | Out-Null
                $definitions = $using:functionDefinitions
                foreach ($functionName in $definitions.Keys) {
                    Set-Item -Path "Function:\$functionName" -Value ([scriptblock]::Create($definitions[$functionName])) -ErrorAction Stop
                }
                $adeDetails = Get-AdeVmDetails -Vm $vm
                $entry = if ($adeDetails) {
                    [PSCustomObject]@{
                        Vm = $vm
                        Ade = $adeDetails
                        UnsupportedReason = Get-UnsupportedAdeScenarioReason -OsType $vm.StorageProfile.OsDisk.OsType -VolumeType $adeDetails.VolumeType
                    }
                }
                [PSCustomObject]@{ VmName = $vm.Name; Entry = $entry; ErrorMessage = $null }
            }
            catch {
                [PSCustomObject]@{ VmName = $vm.Name; Entry = $null; ErrorMessage = $_.Exception.Message }
            }
        } -ThrottleLimit $DiscoveryThrottleLimit)
        $discoveryErrors = @($discoveryResults | Where-Object ErrorMessage)
        if ($discoveryErrors.Count -gt 0) {
            $errorSummary = @($discoveryErrors | ForEach-Object { "$($_.VmName): $($_.ErrorMessage)" }) -join "; "
            throw "ADE discovery failed for one or more VMs. $errorSummary"
        }
        $adeVirtualMachines = @($discoveryResults | Where-Object Entry | ForEach-Object Entry | Sort-Object { $_.Vm.Name })
    }
    else {
        $discoveryProgressId = 10
        try {
            $adeVirtualMachines = @(
                for ($index = 0; $index -lt $resourceGroupVirtualMachines.Count; $index++) {
                    $vm = $resourceGroupVirtualMachines[$index]
                    $percentComplete = [math]::Floor((($index + 1) / $resourceGroupVirtualMachines.Count) * 100)
                    Write-Progress -Id $discoveryProgressId -Activity "Discovering ADE-enabled VMs" -Status ("Inspecting {0} ({1} of {2})" -f $vm.Name, ($index + 1), $resourceGroupVirtualMachines.Count) -PercentComplete $percentComplete
                    $adeDetails = Get-AdeVmDetails -Vm $vm
                    if ($adeDetails) {
                        [PSCustomObject]@{
                            Vm = $vm
                            Ade = $adeDetails
                            UnsupportedReason = Get-UnsupportedAdeScenarioReason -OsType $vm.StorageProfile.OsDisk.OsType -VolumeType $adeDetails.VolumeType
                        }
                    }
                }
            )
        }
        finally {
            Write-Progress -Id $discoveryProgressId -Activity "Discovering ADE-enabled VMs" -Completed
        }
    }
    if ($adeVirtualMachines.Count -eq 0) { throw "No ADE-enabled VMs were found in resource group '$ResourceGroupName'." }
    $supportedVirtualMachines = @($adeVirtualMachines | Where-Object { -not $_.UnsupportedReason })
    $unsupportedVirtualMachines = @($adeVirtualMachines | Where-Object UnsupportedReason)
    while ($true) {
        Show-SubscriptionHeader
        Write-Host "Choose one or more supported ADE-enabled VMs in '$ResourceGroupName'" -ForegroundColor Cyan
        for ($index = 0; $index -lt $supportedVirtualMachines.Count; $index++) {
            $entry = $supportedVirtualMachines[$index]
            $kekLabel = if ($entry.Ade.KeyEncryptionKeyUrl) { "Yes" } else { "No" }
            $keyVaultName = if ($entry.Ade.KeyVaultResourceId -match "/vaults/([^/]+)$") { $Matches[1] } else { "Unknown" }
            Write-Host ("[{0}] {1} ({2}, ADE {3}, KEK: {4}, KV: {5})" -f ($index + 1), $entry.Vm.Name, $entry.Vm.StorageProfile.OsDisk.OsType, $entry.Ade.VolumeType, $kekLabel, $keyVaultName)
        }
        if ($unsupportedVirtualMachines.Count -gt 0) {
            Write-Host ""
            Write-Host "Unavailable VMs" -ForegroundColor Yellow
            foreach ($entry in $unsupportedVirtualMachines) {
                Write-Host ("[-] {0} ({1}, ADE {2})" -f $entry.Vm.Name, $entry.Vm.StorageProfile.OsDisk.OsType, $entry.Ade.VolumeType) -ForegroundColor Yellow
                Write-Host "    $($entry.UnsupportedReason)" -ForegroundColor Yellow
            }
        }
        Write-Host ""
        if ($supportedVirtualMachines.Count -gt 0) { Write-Host "[A] All supported VMs" }
        Write-Host "[R] Export all discovered ADE VMs to CSV"
        Write-Host "[0] Cancel"
        if ($supportedVirtualMachines.Count -gt 0) { Write-Host "Use commas or ranges, for example: 1,3-5" }
        $selection = (Read-Host "Enter selection").Trim()
        if ($selection -eq "0") { throw "Selection cancelled." }
        if ($selection -match "^(?i:r|report)$") {
            try { Export-AdeDiscoveryReport -DiscoveredVirtualMachines $adeVirtualMachines -ResourceGroupName $ResourceGroupName }
            catch { Write-Warning "Could not export the ADE discovery report: $($_.Exception.Message)" }
            continue
        }
        if ($supportedVirtualMachines.Count -eq 0) {
            Write-Warning "No supported VMs are available. Enter R to export the discovery report or 0 to cancel."
            continue
        }
        try {
            $indexes = @(ConvertFrom-SelectionList -Selection $selection -Maximum $supportedVirtualMachines.Count)
            if ($indexes.Count -gt 0) { return @($indexes | ForEach-Object { $supportedVirtualMachines[$_ - 1].Vm.Name }) }
        }
        catch { Write-Warning $_.Exception.Message }
    }
}

function Select-Stage {
    Show-SubscriptionHeader
    Write-Host "Choose operation" -ForegroundColor Cyan
    Write-Host "Prepare starts ADE decryption, which continues inside the guest and can take hours."
    Write-Host "Migrate verifies decryption in Azure and inside the guest, creates clean disk copies,"
    Write-Host "then replaces the VM with encryption at host enabled. Original disks are retained."
    Write-Host ""
    Write-Host "[1] Prepare: start ADE decryption"
    Write-Host "[2] Migrate: verify decryption, copy disks, and replace the VM"
    Write-Host "[0] Cancel"
    switch ((Read-Host "Enter selection").Trim()) {
        "1" { return "Prepare" }
        "2" { return "Migrate" }
        "0" { throw "Selection cancelled." }
        default { throw "Invalid operation selection." }
    }
}

function Test-EncryptedState {
    param([AllowNull()][object]$Value)
    return [string]$Value -in @("Encrypted", "EncryptionInProgress", "DecryptionInProgress")
}

function Get-MigrationScenario {
    param(
        [Parameter(Mandatory)][object]$Vm,
        [Parameter(Mandatory)][object]$EncryptionStatus,
        [Parameter(Mandatory)][string]$RequestedVolumeType,
        [Parameter(Mandatory)][string]$DiscoveredVolumeType,
        [switch]$AllowDecrypted
    )

    $osEncrypted = Test-EncryptedState $EncryptionStatus.OsVolumeEncrypted
    $dataEncrypted = Test-EncryptedState $EncryptionStatus.DataVolumesEncrypted
    $detected = if ($osEncrypted -and $dataEncrypted) { "All" } elseif ($osEncrypted) { "OS" } elseif ($dataEncrypted) { "Data" } else { "None" }
    $effective = if ($RequestedVolumeType -ne "Auto") {
        $RequestedVolumeType
    }
    elseif ($DiscoveredVolumeType -in @("OS", "Data", "All")) {
        $DiscoveredVolumeType
    }
    else {
        $detected
    }
    $osType = [string]$Vm.StorageProfile.OsDisk.OsType

    if ($detected -eq "None" -and (-not $AllowDecrypted -or $effective -notin @("OS", "Data", "All"))) {
        throw "VM '$($Vm.Name)' does not report ADE-encrypted volumes and its former ADE scope could not be detected. Specify -VolumeType OS, Data, or All."
    }
    if ($detected -ne "None" -and $RequestedVolumeType -ne "Auto" -and $RequestedVolumeType -ne $detected) {
        throw "VM '$($Vm.Name)' reports ADE scope '$detected', not requested scope '$RequestedVolumeType'. Use -VolumeType Auto or the detected scope."
    }
    $unsupportedReason = Get-UnsupportedAdeScenarioReason -OsType $osType -VolumeType $effective
    return [PSCustomObject]@{ Supported = -not $unsupportedReason; OsType = $osType; VolumeType = $effective; Reason = $unsupportedReason }
}

function Get-VmPowerState {
    param([Parameter(Mandatory)][object]$VmStatus)

    return [string](($VmStatus.Statuses | Where-Object Code -like "PowerState/*" | Select-Object -First 1).Code) -replace "^PowerState/", ""
}

function Wait-VmPowerState {
    param(
        [string]$ResourceGroupName,
        [string]$VmName,
        [string]$ExpectedState,
        [int]$TimeoutMinutes,
        [string]$TimeoutMessage
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $status = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status -ErrorAction Stop
        $powerState = Get-VmPowerState -VmStatus $status
        if ($powerState -eq $ExpectedState) { return }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    throw $TimeoutMessage
}

function Wait-VmDeallocated {
    param([string]$ResourceGroupName, [string]$VmName, [int]$TimeoutMinutes = 30)

    Wait-VmPowerState -ResourceGroupName $ResourceGroupName -VmName $VmName -ExpectedState "deallocated" -TimeoutMinutes $TimeoutMinutes -TimeoutMessage "VM '$VmName' did not deallocate within $TimeoutMinutes minutes."
}

function Wait-VmDeleted {
    param([string]$ResourceGroupName, [string]$VmName, [int]$TimeoutMinutes = 15)

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        if (-not (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "VM '$VmName' was not deleted within $TimeoutMinutes minutes."
}

function Wait-VmRunning {
    param([string]$ResourceGroupName, [string]$VmName, [int]$TimeoutMinutes = 15)

    Wait-VmPowerState -ResourceGroupName $ResourceGroupName -VmName $VmName -ExpectedState "running" -TimeoutMinutes $TimeoutMinutes -TimeoutMessage "VM '$VmName' did not reach the running state within $TimeoutMinutes minutes."
}

function Wait-NetworkInterfacesDetached {
    param(
        [Parameter(Mandatory)][object[]]$NetworkInterfaces,
        [int]$TimeoutMinutes = 15
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $attachedNetworkInterfaces = @()
        foreach ($networkInterface in $NetworkInterfaces) {
            $currentNetworkInterface = Get-AzNetworkInterface -ResourceGroupName $networkInterface.ResourceGroupName -Name $networkInterface.Name -ErrorAction SilentlyContinue
            if (-not $currentNetworkInterface) {
                throw "Original NIC '$($networkInterface.Name)' was not preserved after source VM deletion."
            }
            if ($currentNetworkInterface.VirtualMachine -and $currentNetworkInterface.VirtualMachine.Id) {
                $attachedNetworkInterfaces += $currentNetworkInterface.Name
            }
        }
        if ($attachedNetworkInterfaces.Count -eq 0) { return }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "NICs '$($attachedNetworkInterfaces -join ', ')' did not detach within $TimeoutMinutes minutes."
}

function Wait-VmExtensionOperationsReady {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [int]$TimeoutMinutes = 15
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $extensions = @(Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VmName -ErrorAction Stop)
        $pendingExtensions = @($extensions | Where-Object { $_.ProvisioningState -in @("Creating", "Updating", "Deleting", "Transitioning") })
        if ($pendingExtensions.Count -eq 0) { return }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "VM '$VmName' extensions are still being modified after $TimeoutMinutes minutes: $($pendingExtensions.Name -join ', ')."
}

function Complete-FailedReplacementAllocation {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Vm)

    $vmSize = [string]$Vm.HardwareProfile.VmSize
    if (-not $PSCmdlet.ShouldProcess("$($Vm.ResourceGroupName)/$($Vm.Name)", "Retry failed replacement allocation with unchanged size $vmSize")) { return $null }

    $retryVm = Get-AzVM -ResourceGroupName $Vm.ResourceGroupName -Name $Vm.Name -ErrorAction Stop
    if ([string]$retryVm.HardwareProfile.VmSize -ne $vmSize) {
        throw "Replacement VM size changed from '$vmSize' to '$($retryVm.HardwareProfile.VmSize)'; refusing allocation retry."
    }
    Update-AzVM -ResourceGroupName $Vm.ResourceGroupName -VM $retryVm -ErrorAction Stop | Out-Null
    $verifiedVm = Get-AzVM -ResourceGroupName $Vm.ResourceGroupName -Name $Vm.Name -ErrorAction Stop
    if ($verifiedVm.ProvisioningState -ne "Succeeded" -or -not $verifiedVm.SecurityProfile.EncryptionAtHost) {
        throw "VM '$($Vm.Name)' did not allocate successfully with its original size '$vmSize'."
    }
    if ([string]$verifiedVm.HardwareProfile.VmSize -ne $vmSize) {
        throw "Recovered VM size '$($verifiedVm.HardwareProfile.VmSize)' does not match original size '$vmSize'."
    }
    Wait-VmRunning -ResourceGroupName $Vm.ResourceGroupName -VmName $Vm.Name
    return $verifiedVm
}

function Assert-AdeDecryptionComplete {
    param(
        [Parameter(Mandatory)][object]$Vm,
        [Parameter(Mandatory)][string]$VolumeType
    )

    $encryptionStatus = Get-AzVMDiskEncryptionStatus -ResourceGroupName $Vm.ResourceGroupName -VMName $Vm.Name -ErrorAction Stop
    $incompleteStates = @("Encrypted", "EncryptionInProgress", "DecryptionInProgress")
    if ($VolumeType -in @("OS", "All") -and [string]$encryptionStatus.OsVolumeEncrypted -in $incompleteStates) {
        throw "VM '$($Vm.Name)' OS volume is still '$($encryptionStatus.OsVolumeEncrypted)'. Complete ADE decryption before migration."
    }
    if ($VolumeType -in @("Data", "All") -and [string]$encryptionStatus.DataVolumesEncrypted -in $incompleteStates) {
        throw "VM '$($Vm.Name)' data volumes are still '$($encryptionStatus.DataVolumesEncrypted)'. Complete ADE decryption before migration."
    }

    $vmStatus = Get-AzVM -ResourceGroupName $Vm.ResourceGroupName -Name $Vm.Name -Status -ErrorAction Stop
    $powerState = Get-VmPowerState -VmStatus $vmStatus
    if ($powerState -ne "running") {
        throw "VM '$($Vm.Name)' must be running for the guest decryption check. Current power state: '$powerState'."
    }

    if ($Vm.StorageProfile.OsDisk.OsType -eq "Windows") {
        $commandId = "RunPowerShellScript"
        $scriptLines = @(
            '$volumes = @(Get-BitLockerVolume -ErrorAction Stop)'
            '$pending = @($volumes | Where-Object { $_.VolumeStatus -ne "FullyDecrypted" -or $_.EncryptionPercentage -ne 0 })'
            'if ($pending.Count -gt 0) {'
            '    $pending | Select-Object MountPoint, VolumeStatus, EncryptionPercentage | Format-Table -AutoSize | Out-String | Write-Output'
            '    throw "One or more BitLocker volumes are not fully decrypted."'
            '}'
            'Write-Output "ADE_DECRYPTION_COMPLETE"'
        )
    }
    else {
        $commandId = "RunShellScript"
        $scriptLines = @(
            'if lsblk -rno TYPE | grep -q "^crypt$"; then'
            '    echo "Active encrypted block mappings:"'
            '    lsblk -rno NAME,TYPE,MOUNTPOINT | grep " crypt " || true'
            '    exit 1'
            'fi'
            'echo "ADE_DECRYPTION_COMPLETE"'
        )
    }

    try {
        $runCommandResult = Invoke-AzVMRunCommand -ResourceGroupName $Vm.ResourceGroupName -VMName $Vm.Name -CommandId $commandId -ScriptString ($scriptLines -join [Environment]::NewLine) -WhatIf:$false -ErrorAction Stop
    }
    catch {
        throw "Could not verify guest decryption for VM '$($Vm.Name)' by using Azure Run Command: $($_.Exception.Message)"
    }
    $guestMessages = @(foreach ($runCommandMessage in @($runCommandResult.Value)) { [string]$runCommandMessage.Message })
    $guestOutput = $guestMessages -join [Environment]::NewLine
    if ($guestOutput -notmatch "ADE_DECRYPTION_COMPLETE") {
        $guestSummary = if ($guestOutput) { $guestOutput.Trim() } else { "Azure Run Command returned no output." }
        throw "VM '$($Vm.Name)' guest decryption is not complete or could not be confirmed. $guestSummary"
    }
}

function Copy-ManagedDiskWithoutAdeMetadata {
    param(
        [Parameter(Mandatory)][object]$SourceDisk,
        [Parameter(Mandatory)][string]$TargetResourceGroupName,
        [Parameter(Mandatory)][string]$TargetDiskName,
        [Parameter(Mandatory)][bool]$IsOsDisk,
        [Parameter(Mandatory)][int]$SasDurationSeconds
    )

    $diskParameters = @{
        Location = $SourceDisk.Location
        CreateOption = "Upload"
        UploadSizeInBytes = ([int64]$SourceDisk.DiskSizeBytes + 512)
        SkuName = $SourceDisk.Sku.Name
        ErrorAction = "Stop"
    }
    if ($IsOsDisk) {
        $diskParameters.OsType = [string]$SourceDisk.OsType
        if ($SourceDisk.HyperVGeneration) { $diskParameters.HyperVGeneration = [string]$SourceDisk.HyperVGeneration }
    }
    if ($SourceDisk.Zones -and @($SourceDisk.Zones).Count -gt 0) { $diskParameters.Zone = [string]$SourceDisk.Zones[0] }

    $targetDiskConfig = New-AzDiskConfig @diskParameters
    if ($SourceDisk.SecurityProfile -and $SourceDisk.SecurityProfile.SecurityType) {
        $targetDiskConfig.SecurityProfile = [Microsoft.Azure.Management.Compute.Models.DiskSecurityProfile]::new()
        $targetDiskConfig.SecurityProfile.SecurityType = [string]$SourceDisk.SecurityProfile.SecurityType
    }
    $targetDisk = New-AzDisk -ResourceGroupName $TargetResourceGroupName -DiskName $TargetDiskName -Disk $targetDiskConfig -ErrorAction Stop
    $sourceAccessGranted = $false
    $targetAccessGranted = $false
    try {
        $sourceSas = Grant-AzDiskAccess -ResourceGroupName $SourceDisk.ResourceGroupName -DiskName $SourceDisk.Name -Access Read -DurationInSecond $SasDurationSeconds -ErrorAction Stop
        $sourceAccessGranted = $true
        $targetSas = Grant-AzDiskAccess -ResourceGroupName $TargetResourceGroupName -DiskName $targetDisk.Name -Access Write -DurationInSecond $SasDurationSeconds -ErrorAction Stop
        $targetAccessGranted = $true
        & azcopy copy $sourceSas.AccessSAS $targetSas.AccessSAS --blob-type PageBlob | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "AzCopy failed with exit code $LASTEXITCODE while copying disk '$($SourceDisk.Name)'." }
    }
    catch {
        Remove-AzDisk -ResourceGroupName $TargetResourceGroupName -DiskName $targetDisk.Name -Force -ErrorAction SilentlyContinue | Out-Null
        throw
    }
    finally {
        if ($sourceAccessGranted) { Revoke-AzDiskAccess -ResourceGroupName $SourceDisk.ResourceGroupName -DiskName $SourceDisk.Name -ErrorAction SilentlyContinue | Out-Null }
        if ($targetAccessGranted) { Revoke-AzDiskAccess -ResourceGroupName $TargetResourceGroupName -DiskName $targetDisk.Name -ErrorAction SilentlyContinue | Out-Null }
    }
    $verifiedTargetDisk = Get-AzDisk -ResourceGroupName $TargetResourceGroupName -DiskName $TargetDiskName -ErrorAction Stop
    if ([string]$verifiedTargetDisk.Sku.Name -ne [string]$SourceDisk.Sku.Name) {
        Remove-AzDisk -ResourceGroupName $TargetResourceGroupName -DiskName $verifiedTargetDisk.Name -Force -ErrorAction SilentlyContinue | Out-Null
        throw "Target disk '$TargetDiskName' SKU '$($verifiedTargetDisk.Sku.Name)' does not match source disk '$($SourceDisk.Name)' SKU '$($SourceDisk.Sku.Name)'."
    }
    return $verifiedTargetDisk
}

function Invoke-PrepareVm {
    [CmdletBinding()]
    param([object]$Vm, [object]$Scenario)

    $progressId = 20
    $activity = "Preparing $($Vm.Name) for encryption-at-host migration"
    try {
        Write-StepProgress -Id $progressId -Activity $activity -Status "Submitting the ADE decryption request" -VmName $Vm.Name -Step 1 -TotalSteps 2
        if ($Scenario.OsType -eq "Windows") {
            Disable-AzVMDiskEncryption -ResourceGroupName $Vm.ResourceGroupName -VMName $Vm.Name -VolumeType $Scenario.VolumeType -Force -ErrorAction Stop | Out-Null
        }
        else {
            if (-not $script:AzureCliAuthenticated) { throw "Linux Prepare requires an authenticated Azure CLI session. Run 'az login' and retry." }
            & az vm encryption disable --resource-group $Vm.ResourceGroupName --name $Vm.Name --volume-type data --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed to start Linux data disk decryption." }
        }
        Write-StepProgress -Id $progressId -Activity $activity -Status "ADE decryption request accepted; guest decryption continues asynchronously" -VmName $Vm.Name -Step 2 -TotalSteps 2
        return "DecryptionStarted"
    }
    finally {
        Write-Progress -Id $progressId -Activity $activity -Completed
    }
}

function Invoke-MigrateVm {
    [CmdletBinding()]
    param([object]$Vm, [object]$Scenario)

    $progressId = 20
    $activity = "Migrating $($Vm.Name) to encryption at host"
    $totalSteps = 12
    try {
    Write-StepProgress -Id $progressId -Activity $activity -Status "Verifying Azure and guest decryption state" -VmName $Vm.Name -Step 1 -TotalSteps $totalSteps
    Assert-AdeDecryptionComplete -Vm $Vm -VolumeType $Scenario.VolumeType

    Write-StepProgress -Id $progressId -Activity $activity -Status "Checking extensions, VM-size support, and network interfaces" -VmName $Vm.Name -Step 2 -TotalSteps $totalSteps
    $extensions = @(Get-AzVMExtension -ResourceGroupName $Vm.ResourceGroupName -VMName $Vm.Name -ErrorAction Stop)
    $otherExtensions = @($extensions | Where-Object { $_.ExtensionType -notin @("AzureDiskEncryption", "AzureDiskEncryptionForLinux") })
    $otherExtensionNames = @($otherExtensions | ForEach-Object { $_.Name })
    if ($otherExtensions.Count -gt 0 -and -not $AllowExtensionLoss -and -not $WhatIfPreference) {
        $extensionNames = $otherExtensionNames -join ", "
        if (-not $script:InteractiveSelection) {
            throw "VM '$($Vm.Name)' has non-ADE extensions ($extensionNames). Recreate them through your deployment source, then rerun with -AllowExtensionLoss."
        }
    }

    $sku = Get-ComputeVmSku -Location $Vm.Location -VmSize $Vm.HardwareProfile.VmSize
    $encryptionCapability = $sku.Capabilities | Where-Object Name -eq "EncryptionAtHostSupported" | Select-Object -First 1
    if (-not $encryptionCapability -or $encryptionCapability.Value -ne "True") {
        throw "VM size '$($Vm.HardwareProfile.VmSize)' in '$($Vm.Location)' does not report EncryptionAtHostSupported=True."
    }
    Assert-EncryptionAtHostFeatureEnabled

    $sourceNicReferences = @($Vm.NetworkProfile.NetworkInterfaces)
    if ($sourceNicReferences.Count -eq 0) { throw "VM '$($Vm.Name)' has no network interfaces to preserve." }
    $primaryNicReference = $sourceNicReferences | Where-Object { $_.Primary -eq $true } | Select-Object -First 1
    $primaryNicId = if ($primaryNicReference) { [string]$primaryNicReference.Id } else { [string]$sourceNicReferences[0].Id }
    $sourceNetworkInterfaces = @(
        foreach ($nicReference in $sourceNicReferences) {
            $nicResourceGroup = Get-ResourceGroupFromId -ResourceId $nicReference.Id
            $nicName = $nicReference.Id.Split("/")[-1]
            $networkInterface = Get-AzNetworkInterface -ResourceGroupName $nicResourceGroup -Name $nicName -ErrorAction Stop
            [PSCustomObject]@{
                Id = $networkInterface.Id
                Name = $networkInterface.Name
                ResourceGroupName = $networkInterface.ResourceGroupName
                IsPrimary = $networkInterface.Id -ieq $primaryNicId
            }
        }
    )

    Write-StepProgress -Id $progressId -Activity $activity -Status "Waiting for extension operations, then removing ADE while the VM is running" -VmName $Vm.Name -Step 3 -TotalSteps $totalSteps
    Wait-VmExtensionOperationsReady -ResourceGroupName $Vm.ResourceGroupName -VmName $Vm.Name
    $adeExtension = Get-AdeExtension -Vm $Vm
    if ($adeExtension) {
        Remove-AzVMDiskEncryptionExtension -ResourceGroupName $Vm.ResourceGroupName -VMName $Vm.Name -Force -ErrorAction Stop | Out-Null
    }

    Write-StepProgress -Id $progressId -Activity $activity -Status "Deallocating the source VM" -VmName $Vm.Name -Step 4 -TotalSteps $totalSteps
    Stop-AzVM -ResourceGroupName $Vm.ResourceGroupName -Name $Vm.Name -Force -ErrorAction Stop | Out-Null
    Wait-VmDeallocated -ResourceGroupName $Vm.ResourceGroupName -VmName $Vm.Name

    Write-StepProgress -Id $progressId -Activity $activity -Status "Loading source disk metadata" -VmName $Vm.Name -Step 5 -TotalSteps $totalSteps
    $sourceOsDiskRg = Get-ResourceGroupFromId $Vm.StorageProfile.OsDisk.ManagedDisk.Id
    $sourceOsDisk = Get-AzDisk -ResourceGroupName $sourceOsDiskRg -DiskName $Vm.StorageProfile.OsDisk.Name -ErrorAction Stop
    $suffix = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
    $newOsDisk = $sourceOsDisk
    if ($Scenario.VolumeType -in @("OS", "All")) {
        Write-StepProgress -Id $progressId -Activity $activity -Status "Creating a clean copy of OS disk '$($sourceOsDisk.Name)'" -VmName $Vm.Name -Step 6 -TotalSteps $totalSteps
        $newOsDisk = Copy-ManagedDiskWithoutAdeMetadata -SourceDisk $sourceOsDisk -TargetResourceGroupName $Vm.ResourceGroupName -TargetDiskName "$($sourceOsDisk.Name)-eah-$suffix" -IsOsDisk $true -SasDurationSeconds $SasDurationSeconds
    }

    $dataDiskContexts = @()
    foreach ($reference in @($Vm.StorageProfile.DataDisks | Sort-Object Lun)) {
        $diskRg = Get-ResourceGroupFromId $reference.ManagedDisk.Id
        $sourceDisk = Get-AzDisk -ResourceGroupName $diskRg -DiskName $reference.Name -ErrorAction Stop
        $targetDisk = $sourceDisk
        if ($Scenario.VolumeType -in @("Data", "All")) {
            Write-StepProgress -Id $progressId -Activity $activity -Status "Creating a clean copy of data disk '$($sourceDisk.Name)' (LUN $($reference.Lun))" -VmName $Vm.Name -Step 6 -TotalSteps $totalSteps
            $targetDisk = Copy-ManagedDiskWithoutAdeMetadata -SourceDisk $sourceDisk -TargetResourceGroupName $Vm.ResourceGroupName -TargetDiskName "$($sourceDisk.Name)-eah-$suffix" -IsOsDisk $false -SasDurationSeconds $SasDurationSeconds
        }
        $dataDiskContexts += [PSCustomObject]@{ Reference = $reference; SourceDisk = $sourceDisk; TargetDisk = $targetDisk }
    }

    Write-StepProgress -Id $progressId -Activity $activity -Status "Building and validating the replacement VM configuration" -VmName $Vm.Name -Step 7 -TotalSteps $totalSteps
    $configParameters = @{ VMName = $Vm.Name; VMSize = $Vm.HardwareProfile.VmSize; ErrorAction = "Stop" }
    if ($Vm.AvailabilitySetReference -and $Vm.AvailabilitySetReference.Id) { $configParameters.AvailabilitySetId = $Vm.AvailabilitySetReference.Id }
    if ($Vm.Zones -and @($Vm.Zones).Count -gt 0) { $configParameters.Zone = [string]$Vm.Zones[0] }
    $newVm = New-AzVMConfig @configParameters
    if ($Scenario.OsType -eq "Windows") {
        $newVm = Set-AzVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Windows -Caching $Vm.StorageProfile.OsDisk.Caching -DeleteOption Detach
    }
    else {
        $newVm = Set-AzVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Linux -Caching $Vm.StorageProfile.OsDisk.Caching -DeleteOption Detach
    }
    foreach ($networkInterface in $sourceNetworkInterfaces) {
        if ($networkInterface.IsPrimary) { $newVm = Add-AzVMNetworkInterface -VM $newVm -Id $networkInterface.Id -Primary -DeleteOption Detach }
        else { $newVm = Add-AzVMNetworkInterface -VM $newVm -Id $networkInterface.Id -DeleteOption Detach }
    }
    foreach ($context in $dataDiskContexts) {
        $reference = $context.Reference
        $newVm = Add-AzVMDataDisk -VM $newVm -Name $context.TargetDisk.Name -ManagedDiskId $context.TargetDisk.Id -Lun $reference.Lun -Caching $reference.Caching -CreateOption Attach -DeleteOption Detach
    }
    if ($Vm.DiagnosticsProfile -and $Vm.DiagnosticsProfile.BootDiagnostics.Enabled) {
        if ($Vm.DiagnosticsProfile.BootDiagnostics.StorageUri) { $newVm = Set-AzVMBootDiagnostic -VM $newVm -Enable -ResourceGroupName $Vm.ResourceGroupName -StorageUri $Vm.DiagnosticsProfile.BootDiagnostics.StorageUri }
        else { $newVm = Set-AzVMBootDiagnostic -VM $newVm -Enable }
    }
    else { $newVm = Set-AzVMBootDiagnostic -VM $newVm -Disable }
    if ($Vm.LicenseType) { $newVm.LicenseType = $Vm.LicenseType }
    if ($Vm.Plan) { $newVm = Set-AzVMPlan -VM $newVm -Publisher $Vm.Plan.Publisher -Product $Vm.Plan.Product -Name $Vm.Plan.Name }
    if ($Vm.SecurityProfile -and $Vm.SecurityProfile.SecurityType) {
        $newVm = Set-AzVMSecurityProfile -VM $newVm -SecurityType $Vm.SecurityProfile.SecurityType
        if ($Vm.SecurityProfile.UefiSettings) { $newVm.SecurityProfile.UefiSettings = $Vm.SecurityProfile.UefiSettings }
    }
    if (-not $newVm.SecurityProfile) { $newVm.SecurityProfile = [Microsoft.Azure.Management.Compute.Models.SecurityProfile]::new() }
    $newVm.SecurityProfile.EncryptionAtHost = $true

    Write-StepProgress -Id $progressId -Activity $activity -Status "Configuring source disks and NICs to detach safely" -VmName $Vm.Name -Step 8 -TotalSteps $totalSteps
    $vmForDetach = Get-AzVM -ResourceGroupName $Vm.ResourceGroupName -Name $Vm.Name -ErrorAction Stop
    $vmForDetach.StorageProfile.OsDisk.DeleteOption = "Detach"
    foreach ($disk in @($vmForDetach.StorageProfile.DataDisks)) { $disk.DeleteOption = "Detach" }
    foreach ($nic in @($vmForDetach.NetworkProfile.NetworkInterfaces)) { $nic.DeleteOption = "Detach" }
    Update-AzVM -ResourceGroupName $Vm.ResourceGroupName -VM $vmForDetach -ErrorAction Stop | Out-Null

    Write-StepProgress -Id $progressId -Activity $activity -Status "Deleting the source VM resource" -VmName $Vm.Name -Step 9 -TotalSteps $totalSteps
    Remove-AzVM -ResourceGroupName $Vm.ResourceGroupName -Name $Vm.Name -Force -ErrorAction Stop | Out-Null
    Wait-VmDeleted -ResourceGroupName $Vm.ResourceGroupName -VmName $Vm.Name

    Write-StepProgress -Id $progressId -Activity $activity -Status "Waiting for preserved network interfaces to detach" -VmName $Vm.Name -Step 10 -TotalSteps $totalSteps
    Wait-NetworkInterfacesDetached -NetworkInterfaces $sourceNetworkInterfaces

    Write-StepProgress -Id $progressId -Activity $activity -Status "Creating the replacement VM with encryption at host" -VmName $Vm.Name -Step 11 -TotalSteps $totalSteps
    New-AzVM -ResourceGroupName $Vm.ResourceGroupName -Location $Vm.Location -VM $newVm -Tag $Vm.Tags -ErrorAction Stop | Out-Null

    Write-StepProgress -Id $progressId -Activity $activity -Status "Verifying encryption at host and the original NIC set" -VmName $Vm.Name -Step 12 -TotalSteps $totalSteps
    Wait-VmRunning -ResourceGroupName $Vm.ResourceGroupName -VmName $Vm.Name
    $verifiedVm = Get-AzVM -ResourceGroupName $Vm.ResourceGroupName -Name $Vm.Name -ErrorAction Stop
    if (-not $verifiedVm.SecurityProfile.EncryptionAtHost) { throw "Replacement VM was created but encryption at host could not be verified." }
    if ([string]$verifiedVm.HardwareProfile.VmSize -ne [string]$Vm.HardwareProfile.VmSize) {
        throw "Replacement VM size '$($verifiedVm.HardwareProfile.VmSize)' does not match original size '$($Vm.HardwareProfile.VmSize)'."
    }
    $expectedNicIds = @($sourceNetworkInterfaces.Id | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    $actualNicIds = @($verifiedVm.NetworkProfile.NetworkInterfaces.Id | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
    if (($expectedNicIds -join "|") -ne ($actualNicIds -join "|")) {
        throw "Replacement VM was created but does not reference the complete original NIC set. Expected: '$($sourceNetworkInterfaces.Name -join ', ')'."
    }
    return [PSCustomObject]@{
        OsDisk = $newOsDisk.Name
        DataDisks = @($dataDiskContexts | ForEach-Object { $_.TargetDisk.Name }) -join ";"
        ReusedNetworkInterfaces = @($sourceNetworkInterfaces.Name) -join ";"
        RetainedSourceDisks = @($sourceOsDisk.Name) + @($dataDiskContexts | ForEach-Object { $_.SourceDisk.Name }) -join ";"
    }
    }
    finally {
        Write-Progress -Id $progressId -Activity $activity -Completed
    }
}

Assert-LocalPrerequisites

$tokenArguments = @("account", "get-access-token", "--output", "none")
if ($SubscriptionId) { $tokenArguments += @("--subscription", $SubscriptionId) }
$null = & az @tokenArguments 2>$null
$script:AzureCliAuthenticated = $LASTEXITCODE -eq 0
if ($script:AzureCliAuthenticated) {
    if ($SubscriptionId) {
        & az account set --subscription $SubscriptionId --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Unable to select subscription '$SubscriptionId'." }
    }
    $account = & az account show --output json --only-show-errors | ConvertFrom-Json
    $accessToken = & az account get-access-token --subscription $account.id --query accessToken --output tsv
    Connect-AzAccount -AccessToken $accessToken -AccountId $account.user.name -Tenant $account.tenantId -Subscription $account.id -WhatIf:$false -ErrorAction Stop | Out-Null
    $script:ActiveSubscriptionLabel = "$($account.name) [$($account.id)]"
    $script:ActiveSubscriptionId = [string]$account.id
    $script:ActiveSubscriptionName = [string]$account.name
}
else {
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context -or -not $context.Subscription) {
        $login = if ($TenantId) { "az login --tenant `"$TenantId`"" } else { "az login" }
        throw "No valid Azure CLI or Az PowerShell session was found. Run '$login' or Connect-AzAccount and try again."
    }
    if ($SubscriptionId -and $SubscriptionId -notin @($context.Subscription.Id, $context.Subscription.Name)) {
        $context = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
    }
    $script:ActiveSubscriptionLabel = "$($context.Subscription.Name) [$($context.Subscription.Id)]"
    $script:ActiveSubscriptionId = [string]$context.Subscription.Id
    $script:ActiveSubscriptionName = [string]$context.Subscription.Name
    Write-Warning "Azure CLI authentication is unavailable; using the active Az PowerShell context. Linux Prepare remains unavailable until 'az login' succeeds."
}

if (-not $ResourceGroupName) {
    $subscriptionScope = "/subscriptions/$script:ActiveSubscriptionId"
    Assert-AzurePermissions -Scope $subscriptionScope -RequiredActions @("Microsoft.Resources/subscriptions/resourceGroups/read") -Purpose "resource-group discovery"
    $ResourceGroupName = Select-ResourceGroup
}
if (-not $Stage) { $Stage = Select-Stage }
if (-not $ResumeAfterAdeRemoval -and $VolumeType -ne "Auto") {
    throw "Normal Prepare and Migrate runs always auto-detect ADE scope. -VolumeType OS, Data, or All is available only with -ResumeAfterAdeRemoval."
}
$resourceGroupScope = "/subscriptions/$script:ActiveSubscriptionId/resourceGroups/$ResourceGroupName"
$requiredAzureActions = @(Get-RequiredAzureActions -Stage $Stage)
Assert-AzurePermissions -Scope $resourceGroupScope -RequiredActions $requiredAzureActions -Purpose "$Stage in resource group '$ResourceGroupName'"
if (-not $VmName -or $VmName.Count -eq 0) { $VmName = Select-VirtualMachines -ResourceGroupName $ResourceGroupName }

$batchPreviewEntries = @(
    foreach ($selectedVmName in $VmName) {
        try {
            $previewVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $selectedVmName -ErrorAction Stop
            $previewAde = Get-AdeVmDetails -Vm $previewVm
            $previewVolumeType = if ($ResumeFailedReplacement) { "Replacement recovery" } elseif ($previewAde -and $previewAde.VolumeType -in @("OS", "Data", "All")) { $previewAde.VolumeType } elseif ($ResumeAfterAdeRemoval) { $VolumeType } else { $null }
            if (-not $previewVolumeType) { continue }
            $previewOsType = [string]$previewVm.StorageProfile.OsDisk.OsType
            if (-not $ResumeFailedReplacement -and (Get-UnsupportedAdeScenarioReason -OsType $previewOsType -VolumeType $previewVolumeType)) { continue }
            $previewExtensionNames = if ($Stage -eq "Migrate") {
                @(Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $selectedVmName -ErrorAction Stop |
                    Where-Object { $_.ExtensionType -notin @("AzureDiskEncryption", "AzureDiskEncryptionForLinux") } |
                    ForEach-Object Name)
            }
            else { @() }
            [PSCustomObject]@{
                VmName = $selectedVmName
                OsType = $previewOsType
                VolumeType = $previewVolumeType
                ExtensionNames = @($previewExtensionNames)
            }
        }
        catch {
            Write-Warning "VM '$selectedVmName' could not be included in the confirmed batch and will not be changed: $($_.Exception.Message)"
        }
    }
)
$batchApproved = $false
if ($batchPreviewEntries.Count -gt 0) {
    $affectedVmLines = @($batchPreviewEntries | ForEach-Object {
        $extensionLabel = if ($Stage -eq "Migrate" -and $_.ExtensionNames.Count -gt 0) { "; extensions lost: $($_.ExtensionNames -join ', ')" } else { "" }
        $scopeLabel = if ($_.VolumeType -eq "Replacement recovery") { $_.VolumeType } else { "$($_.VolumeType) volumes" }
        "VM: $ResourceGroupName/$($_.VmName) [$($_.OsType), $scopeLabel$extensionLabel]"
    })
    if ($Stage -eq "Prepare") {
        Write-OperationPreview -Title "ADE decryption batch preview" -Description @(
            "Affected VMs: $($batchPreviewEntries.Count)"
            $affectedVmLines
            "Action: submit Azure Disk Encryption decryption requests inside each guest"
        ) -Consequences @(
            "Decryption can take hours, can affect disk performance, and can restart the affected VMs."
            "Interrupting decryption can leave one or more VMs in an incomplete state."
            "This stage does not replace VMs; run Migrate only after decryption is fully verified."
        )
        $batchAction = "Start Azure Disk Encryption decryption for $($batchPreviewEntries.Count) VM(s)"
    }
    else {
        Write-OperationPreview -Title "Encryption-at-host migration batch preview" -Description @(
            "Affected VMs: $($batchPreviewEntries.Count)"
            $affectedVmLines
            "Action: sequentially deallocate, upload-copy ADE disks, delete/recreate each VM, and enable encryption at host"
        ) -Consequences @(
            "Migration causes downtime, removes ADE extensions, creates billable disk copies, and deletes and recreates the affected VM resources."
            "Non-ADE extensions listed above cannot be preserved and must be reinstalled."
            "Recreation can affect VM identity and domain membership; allocation failure can leave a failed replacement resource requiring recovery."
            "Original managed disks are retained for rollback, but a tested backup is still required."
        )
        $batchAction = "Migrate $($batchPreviewEntries.Count) VM(s) from ADE to encryption at host"
    }
    $batchApproved = $PSCmdlet.ShouldProcess(($affectedVmLines -join [Environment]::NewLine), $batchAction)
}

$startedAtUtc = (Get-Date).ToUniversalTime()
$batchPreviewVmNames = @($batchPreviewEntries | ForEach-Object { $_.VmName })
$results = foreach ($selectedVmName in $VmName) {
    $adeDetails = $null
    $scenario = $null
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $selectedVmName -ErrorAction Stop
        if ($ResumeFailedReplacement) {
            if ($Stage -ne "Migrate") { throw "-ResumeFailedReplacement can only be used with -Stage Migrate." }
            if ($selectedVmName -notin $batchPreviewVmNames -or -not $batchApproved) {
                New-MigrationResult -ResourceGroupName $ResourceGroupName -VmName $selectedVmName -Stage $Stage -Status "WhatIf" -Details "Replacement recovery was not executed because the VM was not in a confirmed batch." -StartedAtUtc $startedAtUtc -RequestedVolumeType $VolumeType -OsType $vm.StorageProfile.OsDisk.OsType -ResultVolumeType $VolumeType -AdeExtension "RemovedBeforeMigration"
                continue
            }
            if ($vm.ProvisioningState -ne "Failed" -or -not $vm.SecurityProfile.EncryptionAtHost) {
                throw "VM '$selectedVmName' is not a failed encryption-at-host replacement resource."
            }
            $recoveredVm = Complete-FailedReplacementAllocation -Vm $vm -Confirm:$false
            if (-not $recoveredVm) { throw "Replacement allocation recovery was not executed." }
            New-MigrationResult -ResourceGroupName $ResourceGroupName -VmName $selectedVmName -Stage $Stage -Status "Completed" -Details "Recovered failed replacement allocation with unchanged VM size '$($recoveredVm.HardwareProfile.VmSize)'; encryption at host verified." -StartedAtUtc $startedAtUtc -RequestedVolumeType $VolumeType -OsType $recoveredVm.StorageProfile.OsDisk.OsType -ResultVolumeType $VolumeType -AdeExtension "RemovedBeforeMigration"
            continue
        }
        $adeDetails = Get-AdeVmDetails -Vm $vm
        if (-not $adeDetails) {
            if (-not $ResumeAfterAdeRemoval) { throw "VM '$selectedVmName' does not have an Azure Disk Encryption extension. Use -ResumeAfterAdeRemoval only when a prior migration attempt removed ADE after complete decryption." }
            if ($Stage -ne "Migrate") { throw "-ResumeAfterAdeRemoval can only be used with -Stage Migrate." }
            if ($VolumeType -eq "Auto") { throw "-ResumeAfterAdeRemoval requires an explicit -VolumeType OS, Data, or All." }
            $adeDetails = Get-AdeRemovalRecoveryDetails -Vm $vm -VolumeType $VolumeType
        }
        $encryptionStatus = $adeDetails.EncryptionStatus
        if (-not $encryptionStatus) { throw "ADE status could not be read for VM '$selectedVmName'." }
        $scenario = Get-MigrationScenario -Vm $vm -EncryptionStatus $encryptionStatus -RequestedVolumeType $VolumeType -DiscoveredVolumeType $adeDetails.VolumeType -AllowDecrypted:($Stage -eq "Migrate")
        if (-not $scenario.Supported) {
            Write-Warning "Skipping VM '$selectedVmName': $($scenario.Reason)"
            New-MigrationResult -ResourceGroupName $ResourceGroupName -VmName $selectedVmName -Stage $Stage -Status "Unsupported" -Details $scenario.Reason -StartedAtUtc $startedAtUtc -Scenario $scenario -AdeDetails $adeDetails -RequestedVolumeType $VolumeType
            continue
        }
        if ($selectedVmName -notin $batchPreviewVmNames -or -not $batchApproved) {
            New-MigrationResult -ResourceGroupName $ResourceGroupName -VmName $selectedVmName -Stage $Stage -Status "WhatIf" -Details "$Stage was not executed because the batch was not confirmed." -StartedAtUtc $startedAtUtc -Scenario $scenario -AdeDetails $adeDetails -RequestedVolumeType $VolumeType
            continue
        }
        if ($Stage -eq "Prepare") {
            $status = Invoke-PrepareVm -Vm $vm -Scenario $scenario
            $details = "Wait for decryption to finish, then run Stage Migrate. The script will verify Azure and guest decryption state."
        }
        else {
            $migration = Invoke-MigrateVm -Vm $vm -Scenario $scenario
            $status = if ($migration) { "Completed" } else { "WhatIf" }
            $details = if ($migration) { "New disks: $($migration.OsDisk); $($migration.DataDisks). Reused NICs: $($migration.ReusedNetworkInterfaces). Original disks retained: $($migration.RetainedSourceDisks)." } else { "Migration was not executed." }
        }
        New-MigrationResult -ResourceGroupName $ResourceGroupName -VmName $selectedVmName -Stage $Stage -Status $status -Details $details -StartedAtUtc $startedAtUtc -Scenario $scenario -AdeDetails $adeDetails -RequestedVolumeType $VolumeType
    }
    catch {
        New-MigrationResult -ResourceGroupName $ResourceGroupName -VmName $selectedVmName -Stage $Stage -Status "Failed" -Details $_.Exception.Message -StartedAtUtc $startedAtUtc -Scenario $scenario -AdeDetails $adeDetails -RequestedVolumeType $VolumeType
    }
}

if ($OutputPath) {
    $resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $outputDirectory = Split-Path -Parent $resolvedOutputPath
    if (-not $outputDirectory) { $outputDirectory = (Get-Location).ProviderPath }
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) { throw "Output directory '$outputDirectory' does not exist." }
    $results | Export-Csv -LiteralPath $resolvedOutputPath -NoTypeInformation -Encoding UTF8
}

$results
$failed = @($results | Where-Object Status -in @("Failed", "Unsupported"))
Write-Host ""
Write-Host "ADE to encryption at host" -ForegroundColor Cyan
Write-Host "  Processed: $($results.Count)"
Write-Host "  Failed or unsupported: $($failed.Count)" -ForegroundColor $(if ($failed.Count) { "Red" } else { "Green" })
if ($OutputPath) { Write-Host "  CSV: $resolvedOutputPath" }