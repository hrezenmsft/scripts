# Azure VM Lifecycle Tools

## Disclaimer

The sample scripts are not supported under any Microsoft standard support program or service. They are provided AS IS without warranty of any kind. The entire risk arising from their use or performance remains with you.

PowerShell tools for Azure VM lifecycle operations and archived blob rehydration.

## Choose a tool

| Script | Purpose |
| --- | --- |
| `Import-AzVhdToManagedDisk.ps1` | Upload a local fixed-size VHD or VHDX into a new Azure managed disk. |
| `Copy-AzVmWithNewSize.ps1` | Clone selected VMs in a resource group using a different VM size. |
| `Convert-AzZonalVmToRegional.ps1` | Replace a zonal VM with a regional VM by recreating its managed disks without zones and reusing its NICs. |
| `Convert-AzVmAdeToEncryptionAtHost.ps1` | Prepare and migrate supported Azure Disk Encryption VMs to encryption at host. |
| `Get-AzVmPlacementInventory.ps1` | Inventory VM placement by name, region, and zonal/regional state (including zone values). |
| `Start-AzBlobRehydration.ps1` | Rehydrate archived blobs to the Hot or Cool access tier. |
| `Copy-AzManagedDisk.ps1` | Copy one or more managed disks across regions, resource groups, or subscriptions. |
| `Move-AzVmToRegion.ps1` | Create a deallocated copy of a VM in another region without changing the source VM. |
| `Rename-AzVmResources.ps1` | Rename a VM resource or selected attached managed disks. |

All scripts support `-WhatIf` and confirmation prompts because they create resources or submit billable operations.

## Shared requirements

- Windows PowerShell 5.1 or PowerShell 7.
- Azure CLI 2.x authenticated with `az login`.
- Permission to create the Azure resources used by the selected operation.

```powershell
git clone https://github.com/hrezenmsft/scripts.git
Set-Location .\scripts\azure-vm-lifecycle-tools
az login
az account set --subscription "<subscription-name-or-id>"
```

Every script verifies the Azure CLI session before doing work. If the session is missing or expired, the script stops and instructs you to run `az login`; no script starts Azure CLI authentication automatically. For multi-tenant accounts, use `az login --tenant "<tenant-id>"` before selecting the subscription.

## Import a VHD or VHDX

### Additional requirements

- An elevated PowerShell session.
- AzCopy available as `azcopy`.
- A fixed-size `.vhd` or `.vhdx` file with a virtual size aligned to 1 MiB.
- The Hyper-V PowerShell module and its `Convert-VHD` cmdlet for VHDX files.
- Enough free space beside the source VHDX for a temporary fixed VHD.
- An existing Azure resource group.

Run the script without required parameters to receive a path prompt followed by destination menus populated from the active subscription. The region menu shows only regions containing resource groups and includes an option to type another physical Azure region. Named parameters remain available for automation and are validated against that subscription.

| Parameter | Description |
| --- | --- |
| `-Path` | Existing local fixed-size `.vhd` or `.vhdx` file. Relative or absolute paths are accepted. |
| `-ResourceGroupName` | Existing destination resource group in the selected subscription. When omitted, choose from a queried list. |
| `-Location` | Azure region CLI name, such as `eastus2` or `westus3`. When omitted, choose a region containing a resource group or type another valid physical region. |
| `-DiskName` | Optional managed disk name. A unique name based on the VHD filename is generated when omitted. |
| `-Sku` | `Standard_LRS` (default), `StandardSSD_LRS`, `Premium_LRS`, or `UltraSSD_LRS`. |
| `-DiskType` | `OS` or `Data`. If omitted, supplying `-OsType` implies `OS`; otherwise choose from a menu. |
| `-OsType` | `Linux` or `Windows`; prompted when omitted for an OS disk and invalid for data disks. |
| `-HyperVGeneration` | `V1` (default) or `V2`; prompted when OS metadata is selected interactively and used only for OS disks. |
| `-SubscriptionId` | Optional subscription name or ID; the active Azure CLI subscription is used when omitted. |

Preview the operation:

```powershell
.\Import-AzVhdToManagedDisk.ps1 -Path .\server.vhd -ResourceGroupName lab-rg -Location eastus2 -WhatIf
```

Upload an OS disk:

```powershell
.\Import-AzVhdToManagedDisk.ps1 `
    -Path .\linux.vhd `
    -ResourceGroupName lab-rg `
    -Location eastus2 `
    -DiskType OS `
    -OsType Linux `
    -HyperVGeneration V2 `
    -Sku Premium_LRS
```

Upload a fixed VHDX OS disk:

```powershell
.\Import-AzVhdToManagedDisk.ps1 `
    -Path .\server.vhdx `
    -ResourceGroupName lab-rg `
    -Location eastus2 `
    -DiskType OS `
    -OsType Windows `
    -HyperVGeneration V2
```

Create a data disk explicitly:

```powershell
.\Import-AzVhdToManagedDisk.ps1 `
    -Path .\data.vhd `
    -ResourceGroupName lab-rg `
    -Location eastus2 `
    -DiskType Data
```

For backward compatibility, omitting `-DiskType` while supplying `-OsType` creates an OS disk. When both are omitted, the script asks whether the upload is an OS or data disk. OS disk selection also prompts for Linux or Windows and Hyper-V generation when those values were not supplied. If `-DiskName` is omitted, the script generates a name from the VHD filename.

For OS disks, the script passes `--os-type` and `--hyper-v-generation` to Azure during managed disk creation, displays those selections in the confirmation prompt, and verifies that Azure retained the expected OS metadata after upload.

The Azure direct-upload endpoint accepts fixed VHD content and validates its `conectix` footer. For VHDX input, the script uses `Convert-VHD` to create a temporary fixed VHD beside the source, uploads that VHD, and removes it afterward. It uses `Get-VHD` for an earlier VHDX check when available; if that check cannot run, conversion remains the authoritative validation step. See the [official Microsoft Learn preparation guidance](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/prepare-for-upload-vhd-image). Pasted paths can include surrounding single or double quotes, including paths containing spaces.

The upload SAS is held in process memory and revoked in a `finally` block. If revocation fails, the script prints the exact recovery command without displaying the SAS URL.

```powershell
Get-Help .\Import-AzVhdToManagedDisk.ps1 -Full
```

## Rehydrate archived blobs

### Additional requirements

- Az PowerShell modules: `Az.Accounts` and `Az.Storage`.
- Management-plane read access to discover storage accounts.
- `Storage Blob Data Contributor` or equivalent data-plane permissions on the target storage account or selected containers.
- Network access permitted by the storage firewall, virtual network rules, or private endpoint configuration.
- A standard general-purpose v2 or Blob Storage account containing archived base blobs.

```powershell
Install-Module Az.Accounts, Az.Storage -Scope CurrentUser
```

Preview every eligible archived blob in a selected storage account:

```powershell
.\Start-AzBlobRehydration.ps1 -WhatIf
```

The script does not start Azure CLI authentication. Run `az login` before the script; for a multi-tenant account, scope login to the tenant containing the subscription:

```powershell
az login --tenant "<tenant-id>"

.\Start-AzBlobRehydration.ps1 `
    -SubscriptionId "<subscription-id>" `
    -TenantId "<tenant-id>" `
    -WhatIf
```

If the Azure CLI session is missing or expired, the script stops and prints the required login command. Az PowerShell may open a browser separately when Az.Storage needs a matching tenant context.

Rehydrate one container to Cool with Standard priority:

```powershell
.\Start-AzBlobRehydration.ps1 `
    -ResourceGroupName archive-rg `
    -StorageAccountName archivestore01 `
    -ContainerName backups `
    -TargetTier Cool `
    -RehydratePriority Standard
```

Use `-ContainerName container1,container2` to limit scanning to multiple containers, `-BatchSize` to control enumeration page size, and `-MaxBlobCount` to cap eligible blobs in one run. Blobs already showing a pending rehydration status are skipped. Supplying `-ContainerName` also supports least-privilege role assignments scoped to those containers because the script does not attempt account-wide container discovery. Omitting it requires permission to list containers at storage-account scope.

An Azure Storage 403 can be caused by either data-plane RBAC or storage networking. Management roles such as Owner or Contributor do not grant blob access; use `Storage Blob Data Contributor`. Storage accounts with public access disabled or a default network action of `Deny` must be reached from an allowed IP/VNet or through a correctly resolved private endpoint. Role assignments can take up to 10 minutes to propagate. The script reports the relevant RBAC scope, network settings, and diagnostic commands when access is denied.

The script uses Microsoft Entra ID for blob enumeration and Azure CLI `--auth-mode login` for tier changes. It does not retrieve account keys or enable shared-key access. Each container has its own continuation-token sequence, so large accounts are paginated correctly.

Changing an archived blob to Hot or Cool can incur retrieval, transaction, online storage, and early deletion charges. Standard priority may take up to 15 hours for smaller blobs under ideal conditions. High priority costs more and should be reserved for urgent restores. Azure processes accepted requests asynchronously, and tier changes cannot be canceled after submission. Review [Microsoft's blob rehydration guidance](https://learn.microsoft.com/azure/storage/blobs/archive-rehydrate-overview) before running the script.

```powershell
Get-Help .\Start-AzBlobRehydration.ps1 -Full
```

## Clone VMs at a new size

### Additional requirements

- Az PowerShell modules: `Az.Accounts` and `Az.Compute`.
- Quota for the target VM size and created disks, snapshots, NICs, and VMs.

```powershell
Install-Module Az.Accounts, Az.Compute -Scope CurrentUser
```

Run without parameters for guided numbered menus:

```powershell
.\Copy-AzVmWithNewSize.ps1
```

The script does not start Azure CLI authentication. Run `az login` first. For accounts with access to multiple tenants, authenticate to the tenant containing the subscription:

```powershell
az login --tenant "<tenant-id>"

.\Copy-AzVmWithNewSize.ps1 `
    -SubscriptionId "<subscription-id>" `
    -TenantId "<tenant-id>"
```

If the Azure CLI session is missing or expired, the script stops and prints the required login command. `-TenantId` is optional but recommended for multi-tenant accounts.

The script prompts for:

1. Source resource group.
2. One or more source VMs.
3. The number of clones to create for each selected VM.
4. A target-size search term and a VM size available to the active subscription in the source VM region.

Each menu displays the active Azure subscription name and ID at the top.

In the source VM menu, enter a single number, comma-separated values such as `1,3,5`, a range such as `2-4`, a combination such as `1,3-5`, or `A` to select all VMs. Enter `0` to cancel. Target-size searches that return more than 50 results ask for a narrower filter.

When multiple VMs are selected, the target menu shows only sizes present in Azure's available-size list for every source VM. Explicit `-TargetVmSize` values are validated against the same per-VM availability data before any resources are created.

Enter an exact target size such as `Standard_D4s_v5` to validate it directly against every selected source VM in the active subscription and region. Enter a partial name such as `D4s_v5` or `Dsv5` to search current Microsoft Learn VM size documentation and choose from documented matches that pass the same availability checks. The script uses Azure's per-VM available resize-size endpoint instead of downloading the slow Resource SKUs catalog.

Use `-CloneCount` to create multiple clones per selected source VM in one run. The accepted range is 1-100 and the default is 1 for noninteractive execution. Each clone receives a unique generated name, disk, and NIC. Clones of the same source share one temporary snapshot; generalized Windows clones also share one Sysprep preparation VM and generalized image. Shared artifacts remain until every clone for that source has been created, then are removed.

Before changing Azure resources, the confirmation prompt summarizes every selected source and target VM, total clone count, and inherited boot diagnostics state. Each clone enables or disables boot diagnostics to match its source VM.

During cloning, a parent progress bar tracks completed or skipped clone plans against the total. A child progress bar reports the current step and total steps for source preparation, each clone, and cleanup; cleanup totals reflect only resources that still exist. Final clones remain running; only a temporary Sysprep preparation VM is deallocated when creating a generalized Windows image.

If cloning or generalization fails for one source VM, the script displays an error message with the failure reason, skips any remaining clone plans for that source, performs best-effort cleanup, and continues with the next selected source VM. Successfully created clones are retained and included in the final results. A failed clone can leave its copied disk or NIC for inspection and manual cleanup.

### Optional Windows generalization

When an interactive selection includes a Windows VM, the script offers two modes:

1. `Specialized` copies the VM as-is and preserves its machine-specific identity.
2. `Generalized` boots a temporary copy on an isolated, unpeered preparation VNet, schedules `sysprep.exe /generalize /oobe /shutdown /quiet` through Azure Run Command, marks only that temporary VM generalized in Azure, captures a temporary managed image, and deploys the final VM with new local administrator credentials on the source subnet.

The selected source VM is never generalized or modified. Use `-GeneralizeWindows` for noninteractive runs and optionally provide `-WindowsAdminCredential`; otherwise the script prompts securely after plan confirmation. Noninteractive execution also requires `-AcknowledgeSysprepPrerequisites`. Linux VMs in a mixed selection remain specialized.

Generalization requires a healthy Azure Windows VM Agent with outbound Azure connectivity. Following the [Microsoft Learn Windows generalization guidance](https://learn.microsoft.com/en-us/azure/virtual-machines/generalize#generalizing-a-windows-vm-before-creating-an-image), the temporary guest preflight verifies that CD/DVD-ROM is enabled, removes `C:\Windows\Panther`, verifies that every BitLocker-capable volume is fully decrypted, and blocks removable-storage deny policies that could prevent Azure OOBE from mounting provisioning media. Microsoft documents `sysprep.exe /generalize /shutdown` for an interactive administrator session; the script adds `/oobe /quiet` because its SYSTEM scheduled task is noninteractive and otherwise waits indefinitely at an invisible mode-selection dialog. It waits for shutdown without restarting the VM, deallocates it, and marks only the temporary VM generalized in Azure. No custom unattend file is used.

The script blocks Trusted Launch VMs and domain controllers. Domain-joined member VMs are booted only on the isolated preparation VNet so they cannot contact the source network with a duplicate machine identity; Sysprep then removes their machine-specific domain identity. The final generalized clone is not domain joined and must be joined to the domain separately if required. Automation cannot prove that every installed application or role supports Sysprep, so the operator must explicitly confirm product-specific requirements for server roles, SQL Server, security agents, Store applications, and Microsoft Defender for Endpoint. Ensure Windows has no pending servicing work. The script removes the temporary VM, preparation NIC/VNet, copied preparation disk, snapshot, and managed image after deployment and makes a best-effort cleanup attempt after failure.

```powershell
.\Copy-AzVmWithNewSize.ps1 `
    -ResourceGroupName lab-rg `
    -SourceVmName winserver01 `
    -TargetVmSize Standard_D4s_v5 `
    -CloneCount 3 `
    -GeneralizeWindows `
    -AcknowledgeSysprepPrerequisites
```

Source NIC metadata and cloned NIC creation use Azure CLI resource IDs. The script does not load Az.Network, avoiding its model-deserialization failures while preserving the source subnet and NIC-level network security group.

Clone one VM without menus:

```powershell
.\Copy-AzVmWithNewSize.ps1 `
    -ResourceGroupName lab-rg `
    -SourceVmName server01 `
    -TargetVmSize Standard_D4s_v5
```

`-SourceVM` is an alias for `-SourceVmName`.

Preview cloning every VM in a resource group:

```powershell
.\Copy-AzVmWithNewSize.ps1 -ResourceGroupName lab-rg -TargetVmSize Standard_D4s_v5 -WhatIf
```

## Migrate Azure Disk Encryption to encryption at host

`Convert-AzVmAdeToEncryptionAtHost.ps1` prepares and migrates supported VMs from Azure Disk Encryption (ADE) to encryption at host. Migration is intentionally split into two runs: `Prepare` starts guest decryption, and `Migrate` verifies decryption before replacing affected disks and the VM resource.

### Additional requirements

- Current Azure CLI, AzCopy on `PATH`, and the Az.Accounts, Az.Compute, Az.Network, and Az.Resources PowerShell modules.
- A current, tested backup of every target VM and a planned maintenance window.
- Permission to read effective Azure permissions and VM/SKU state; run VM commands; manage VM extensions; grant and revoke disk access; and create, update, delete, and recreate VMs and disks.
- Public managed-disk network access from the machine running AzCopy. Private disk access configurations require an equivalent private transfer path and are not handled.
- Enough quota and budget for temporary duplicate managed disks.

```powershell
winget install Microsoft.AzureCLI
winget install Microsoft.AzCopy.10
Install-Module Az.Accounts,Az.Compute,Az.Network,Az.Resources -Scope CurrentUser
```

At startup, the script displays a data-loss and backup warning, checks local dependencies, validates executable health, authenticates through the current Azure CLI or Az PowerShell session, and performs a read-only effective-permissions check for the selected stage. Missing dependencies or Azure actions are listed with remediation guidance before VM discovery or modification.

Run without parameters for resource-group, operation, and multiple-VM menus. PowerShell 7 inspects up to eight VMs concurrently by default; use `-DiscoveryThrottleLimit 1` for sequential discovery or choose a value through 32. Windows PowerShell 5.1 discovery is sequential. Prepare and Migrate execution remains sequential.

```powershell
.\Convert-AzVmAdeToEncryptionAtHost.ps1
```

The VM menu lists only VMs with the Windows or Linux ADE extension. `A` selects every supported VM, while unsupported scenarios are shown separately. Use `R` to export the complete ADE discovery inventory to CSV.

Start decryption for selected VMs:

```powershell
.\Convert-AzVmAdeToEncryptionAtHost.ps1 `
    -ResourceGroupName rg-prod `
    -VmName app01,app02 `
    -Stage Prepare
```

Wait for guest decryption to finish, then preview migration:

```powershell
.\Convert-AzVmAdeToEncryptionAtHost.ps1 `
    -ResourceGroupName rg-prod `
    -VmName app01,app02 `
    -Stage Migrate `
    -WhatIf
```

ADE volume scope is detected automatically from extension metadata, including after Azure reports the volumes as decrypted. The only explicit `-VolumeType` override is for guarded `-ResumeAfterAdeRemoval` recovery, because the extension metadata is already gone.

Prepare and Migrate each show one batch warning listing all supported affected VMs, detected scopes, and migration extension loss. One confirmation applies to the complete batch; fresh checks still run before each VM is changed. `-Confirm:$false` is available for explicitly approved unattended automation.

### Supported scenarios

| Operating system | ADE scope | Behavior |
| --- | --- | --- |
| Windows | OS | Decrypts and upload-copies the OS disk. Unaffected data disks are reattached. |
| Windows | All | Decrypts and upload-copies every managed disk. |
| Windows | Data only | Blocked as an unsupported ADE migration pattern. |
| Linux | Data only | Decrypts and upload-copies data disks. The unaffected OS disk is reattached. |
| Linux | OS or All | Blocked. Deploy a fresh encryption-at-host VM and migrate the workload. |

Migrate verifies Azure status and guest state before modification. Windows requires all BitLocker volumes to be fully decrypted at zero percent encryption. Linux requires no active `crypt` mappings. Failure or missing Azure Run Command output blocks migration.

Full or incremental snapshots and normal managed-disk copies retain the ADE Unified Data Encryption flag and cannot create clean migration disks. The script follows the supported upload-copy process with source and target disk SAS grants and AzCopy, then revokes access in a `finally` block. Avoid transcript or verbose process-command logging because SAS URLs exist in process memory during transfer.

The replacement preserves the original VM size and disk SKUs. It also preserves availability set or zone, disk caching and LUNs, boot diagnostics, tags, license type, Marketplace plan, security type, Trusted Launch UEFI settings, and exact NIC resource IDs where represented by Az PowerShell. Original disks are retained for rollback. Non-ADE extensions cannot be recreated because protected settings are unavailable and must be reinstalled from an authoritative deployment source.

If allocation of the exact original VM size fails, retry later with `-ResumeFailedReplacement`; the script does not select another size. If a prior attempt removed ADE but the original VM was restored, use `-ResumeAfterAdeRemoval` with an explicit former scope after verifying complete decryption.

```powershell
Get-Help .\Convert-AzVmAdeToEncryptionAtHost.ps1 -Full
```

Review [Microsoft's ADE migration guidance](https://learn.microsoft.com/azure/virtual-machines/disk-encryption-migrate) before production use. Domain membership, VM identity, extensions, backup, monitoring, and application health require validation after replacement.

## Convert a zonal VM to regional

### Additional requirements

- Az PowerShell modules: `Az.Accounts`, `Az.Compute`, and `Az.Resources`.
- Permission to stop/delete the source VM and create replacement disks, snapshots, and the new VM.
- A zonal VM that uses managed disks.
- A maintenance window, because the source VM is stopped, deleted, and recreated with the same name.

```powershell
Install-Module Az.Accounts, Az.Compute, Az.Resources -Scope CurrentUser
```

Run without parameters for guided numbered menus:

```powershell
.\Convert-AzZonalVmToRegional.ps1
```

The script does not start Azure CLI authentication. Run `az login` first. For accounts with access to multiple tenants, authenticate to the tenant containing the subscription:

```powershell
az login --tenant "<tenant-id>"

.\Convert-AzZonalVmToRegional.ps1 `
    -SubscriptionId "<subscription-id>" `
    -TenantId "<tenant-id>"
```

If the Azure CLI session is missing or expired, the script stops and prints the required login command. `-TenantId` is optional but recommended for multi-tenant accounts.

The script prompts for:

1. Source resource group.
2. Source zonal VM.

Each menu displays the active Azure subscription name and ID at the top. The VM picker lists only zonal VMs in the selected resource group and also supports manual entry.

Preview the conversion:

```powershell
.\Convert-AzZonalVmToRegional.ps1 `
    -ResourceGroupName prod-rg `
    -VmName app01 `
    -WhatIf
```

Convert a zonal VM and keep its current size:

```powershell
.\Convert-AzZonalVmToRegional.ps1 `
    -ResourceGroupName prod-rg `
    -VmName app01
```

Convert a zonal VM and change the VM size during recreation:

```powershell
.\Convert-AzZonalVmToRegional.ps1 `
    -ResourceGroupName prod-rg `
    -VmName app01 `
    -TargetVmSize Standard_D4s_v5
```

Convert a zonal VM and force the replacement disks to a target SKU:

```powershell
.\Convert-AzZonalVmToRegional.ps1 `
    -ResourceGroupName prod-rg `
    -VmName app01 `
    -TargetDiskSkuName Premium_LRS
```

Keep the temporary snapshots for a rollback window:

```powershell
.\Convert-AzZonalVmToRegional.ps1 `
    -ResourceGroupName prod-rg `
    -VmName app01 `
    -KeepSnapshots
```

The script snapshots the source OS disk and every attached data disk, creates new regional managed disks by intentionally omitting zone assignment, stops the source VM if needed, updates delete options to detach NICs and disks, deletes the source VM object, and recreates the VM with the same name. It preserves attached NICs, boot diagnostics configuration, license type, marketplace plan metadata, security profile, tags, and data-disk LUN and caching settings where Azure allows them on the replacement VM.

This is an in-place replacement, not an online migration. The original VM resource is deleted, and the original managed disks remain detached after recreation so you can validate the replacement VM before manual cleanup. If `-KeepSnapshots` is omitted, temporary snapshots are removed automatically after successful completion.

The script warns if the VM is not marked zonal at the VM resource level, but it still continues so you can handle cases where zonal behavior is represented primarily by the attached disks. Review the confirmation summary carefully, because `-TargetVmName` is reserved and the script always recreates the VM with the original name.

After validation, manually remove the original source disks and any retained snapshots listed in the cleanup summary to avoid ongoing charges.

```powershell
Get-Help .\Convert-AzZonalVmToRegional.ps1 -Full
```

Clone only VMs at a specific source size:

```powershell
.\Copy-AzVmWithNewSize.ps1 `
    -ResourceGroupName lab-rg `
    -SourceVmSize Standard_D2s_v5 `
    -TargetVmSize Standard_D4s_v5
```

For backward-compatible bulk automation, supplying `-ResourceGroupName` and `-TargetVmSize` without a source VM or source-size filter processes every VM in the resource group.

Specialized clones receive an OS disk copied from the shared source snapshot. Generalized Windows clones receive an OS disk provisioned from the shared temporary managed image. Every clone receives a new NIC in the source VM's first subnet and remains running after creation. Shared temporary artifacts are removed in a `finally` block.

### Clone limitations

- Source VMs are not modified.
- Specialized clones retain the guest hostname, accounts, machine identity, and domain membership.
- Generalized Windows clones receive a new computer name and machine identity, reuse the supplied local administrator credentials, and are not domain joined.
- Only the OS disk and first NIC/subnet are used.
- Data disks, additional NICs, public IPs, extensions, identities, tags, zones, availability settings, and custom IP configurations are not copied.
- Accelerated networking is disabled unless `-EnableAcceleratedNetworking` is supplied and must be supported by the target size and guest.
- A failed clone can leave its copied disk or NIC for inspection and manual cleanup; temporary shared artifacts are removed on a best-effort basis.

```powershell
Get-Help .\Copy-AzVmWithNewSize.ps1 -Full
```

## Copy managed disks

`Copy-AzManagedDisk.ps1` copies selected managed disks by creating temporary incremental snapshots, copying snapshots to the target region, and creating target managed disks. It supports interactive selection of a VM and its attached disks, including `A` for all attached disks, and it can target another subscription or resource group.

The script requires an Azure CLI MFA-backed session. It checks the access token for an MFA claim, offers device-code reauthentication when needed, and uses one confirmation for the complete plan. Target regions must support managed snapshots. Temporary source and target snapshots are deleted after every copy attempt.

```powershell
.\Copy-AzManagedDisk.ps1 `
    -SourceResourceGroupName source-rg `
    -SourceDiskName app01-osdisk,app01-data01 `
    -TargetResourceGroupName target-rg `
    -TargetRegion brazilsouth
```

Azure validates target disk and snapshot SKU availability during creation. If Azure rejects a SKU or target region, no target disk is created for that copy attempt.

```powershell
Get-Help .\Copy-AzManagedDisk.ps1 -Full
```

## Move a VM to another region

`Move-AzVmToRegion.ps1` creates a copy of a selected VM in another region without changing the source VM. It copies the OS disk and, optionally, all data disks through temporary snapshots; recreates NICs in user-selected target VNet and subnet; recreates public IP resources; and leaves the target VM deallocated.

It preserves static private IP addresses where available, offers dynamic addressing when they are unavailable, preserves NIC IP forwarding, accelerated networking, custom DNS servers, VM tags, and managed boot diagnostics. New public IP addresses differ from the source and are included in the final summary. When no target VM name is supplied, a random five-character suffix is used consistently for target VM, disk, and NIC names.

```powershell
.\Move-AzVmToRegion.ps1 `
    -SourceResourceGroupName source-rg `
    -SourceVmName app01 `
    -TargetResourceGroupName target-rg `
    -TargetRegion brazilsouth `
    -TargetVnetName target-vnet `
    -TargetSubnetName default `
    -IncludeDataDisks
```

The script blocks or warns about configurations it cannot safely reproduce, including zonal VMs, availability sets, dedicated hosts, proximity placement groups, marketplace plans, extensions, managed identities, and NIC network security groups. Temporary snapshots are deleted after each disk copy.

```powershell
Get-Help .\Move-AzVmToRegion.ps1 -Full
```

## Rename VM resources

`Rename-AzVmResources.ps1` operates on a selected VM and offers two exclusive modes: rename the VM resource while retaining its disks, or rename selected attached OS/data disks while retaining the VM name. Both modes deallocate the VM and restore its original running state afterward.

Disk-only mode lets you select individual disks, ranges, or all attached disks. It swaps a selected OS disk in place. For each selected data disk, it attaches the replacement at the original LUN with its original caching setting, verifies that Azure reports the expected LUN mapping, and only then deletes the original disk. The VM resource is not deleted in disk-only mode.

```powershell
.\Rename-AzVmResources.ps1 `
    -ResourceGroupName app-rg `
    -VmName app01 `
    -RenameDisks `
    -DiskName app01-osdisk,app01-data01
```

VM-resource rename deletes and recreates only the VM resource after setting disks and NICs to `Detach`. Data disks are attached in the VM creation action before the VM is started. The script removes unattached replacement disks created during a failed disk rename.

```powershell
Get-Help .\Rename-AzVmResources.ps1 -Full
```

## Inventory VM placement

Generate a VM inventory that shows each VM name, region, whether it is zonal
or regional, and the zone values when present.

The final report is rendered once as a single table with these columns:
`Name`, `ResourceGroupName`, `Region`, `Placement`, and `Zone`.

Run with guided menus:

```powershell
.\Get-AzVmPlacementInventory.ps1
```

Inventory one resource group:

```powershell
.\Get-AzVmPlacementInventory.ps1 -ResourceGroupName lab-rg
```

Inventory all resource groups in the active subscription:

```powershell
.\Get-AzVmPlacementInventory.ps1 -AllResourceGroups
```

Like other tools in this repository, this script expects a valid Azure CLI
session and does not run `az login` for you.

```powershell
Get-Help .\Get-AzVmPlacementInventory.ps1 -Full
```

## Security and cost

- Review `-WhatIf` output before creating resources.
- Azure disks, snapshots, NICs, and VMs can incur charges.
- Generalized Windows cloning requests a local administrator credential through `Get-Credential`; the credential remains in process memory and is passed to Azure deployment without being written to disk by the script.
- Avoid verbose or transcript logging when debugging token-bearing commands.
- Review all cloned resources before deleting or changing a source VM.

## Author

Henrique Rezende

## License

Licensed under the [MIT License](LICENSE).