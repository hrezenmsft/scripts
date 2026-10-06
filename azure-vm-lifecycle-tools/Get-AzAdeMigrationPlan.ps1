<#
.SYNOPSIS
Analyzes an Azure subscription and builds a migration plan from Azure Disk Encryption (ADE) to encryption at host.

.DESCRIPTION
Get-AzAdeMigrationPlan inventories every virtual machine in a subscription (optionally filtered by resource
group), detects Azure Disk Encryption usage, and classifies each VM into the migration path described in the
Microsoft Learn article "Migrate from Azure Disk Encryption to encryption at host".

The script produces:
- A self-contained HTML report with a table of contents, executive summary, prerequisite checklist,
  per-path step-by-step procedures (with PowerShell and Azure CLI commands), per-VM tables, effort estimates,
  blockers, and a Key Vault cleanup list.
- An optional CSV file with one row per VM.
- One PSCustomObject per VM written to the pipeline.

This script is READ-ONLY. It only calls Get-* cmdlets and read-only Azure CLI commands. It does not change VMs,
disks, extensions, Key Vaults, feature registrations, or backups. Use the report to plan the migration and run
the documented steps (or an automation tool) during an approved maintenance window.

To keep large subscriptions fast, subscription-wide data (VMs, power states, disks, VM SKUs) is read in bulk
once, and the per-VM calls (extensions, ADE encryption status, backup status) run in parallel in a runspace
pool limited by -ThrottleLimit. This works on Windows PowerShell 5.1 and PowerShell 7.

Authentication follows the same logic as the other scripts in this repository: an existing Azure CLI session
is reused when available; otherwise an existing Az PowerShell context is used. The script never starts an
interactive sign-in.

.PARAMETER SubscriptionId
The subscription ID to analyze.

.PARAMETER TenantId
Optional tenant ID. Used only in the sign-in guidance shown when no valid session is found.

.PARAMETER ResourceGroupName
Optional list of resource groups to analyze. Names are validated against the subscription.
When neither -ResourceGroupName nor -AllResourceGroups is supplied, the script lists the resource groups
in the subscription (with their VM counts) and asks you to pick one or more, or ALL.

.PARAMETER AllResourceGroups
Analyzes every resource group in the subscription without prompting. Use this for unattended runs.

.PARAMETER OutputPath
Path of the HTML report, or an existing directory. When a directory (or nothing) is supplied, the file name
AdeMigrationPlan-<subscriptionName>-<resourceGroup|AllRGs>-<yyyyMMdd-HHmmss>.html is used. The parent directory must already exist.

.PARAMETER CsvPath
Optional path of a CSV file with one row per VM. The parent directory must already exist.

.PARAMETER IncludeNonAdeVms
Includes VMs that do not use ADE (already using encryption at host, or no ADE) in the detailed VM tables.
They are always counted in the summary.

.PARAMETER SkipBackupCheck
Skips the Azure Backup protection lookup (Az.RecoveryServices). Use this to speed up large subscriptions.

.PARAMETER CopyThroughputMBps
Assumed AzCopy disk copy throughput in MB/s used for the copy time estimate. Default: 200.

.PARAMETER ThrottleLimit
Maximum number of VMs analyzed in parallel (runspace pool). Default: 10. Raise it for large subscriptions;
lower it if you see Azure Resource Manager throttling (HTTP 429) warnings.

.PARAMETER PassThru
Also returns the per-VM result objects to the pipeline. By default the script writes nothing but the report
path(s) to the console; use -Verbose to see progress messages.

.EXAMPLE
.\Get-AzAdeMigrationPlan.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000

Lists the resource groups in the subscription, asks which ones to scan (or ALL), and writes the HTML report
to the current directory.

.EXAMPLE
.\Get-AzAdeMigrationPlan.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -AllResourceGroups

Analyzes the whole subscription without prompting.

.EXAMPLE
.\Get-AzAdeMigrationPlan.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-app1,rg-app2 -OutputPath .\reports -CsvPath .\reports\ade-plan.csv

Analyzes two resource groups and writes both an HTML report and a CSV file.

.EXAMPLE
$plan = .\Get-AzAdeMigrationPlan.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -AllResourceGroups -SkipBackupCheck -PassThru
$plan | Where-Object MigrationPath -like 'Windows*' | Format-Table VmName, ResourceGroup, EffortHours

Captures the per-VM objects for further filtering.

.EXAMPLE
.\Get-AzAdeMigrationPlan.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -AllResourceGroups -ThrottleLimit 20 -SkipBackupCheck

Analyzes a large subscription with 20 VMs processed in parallel and no backup lookup.

.NOTES
Author: Henrique Rezende
Version: 1.5.1
Requires: Az.Accounts, Az.Compute, Az.Resources. Optional: Az.RecoveryServices, Azure CLI.
Minimum role: Reader on the subscription (Key Vault and Backup data is read through ARM only).

.LINK
https://github.com/hrezenmsft/azure-vm-lifecycle-tools

.LINK
https://learn.microsoft.com/azure/virtual-machines/disk-encryption-migrate
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [string]$TenantId,

    [string[]]$ResourceGroupName,

    [switch]$AllResourceGroups,

    [string]$OutputPath,

    [string]$CsvPath,

    [switch]$IncludeNonAdeVms,

    [switch]$SkipBackupCheck,

    [ValidateRange(10, 2000)]
    [int]$CopyThroughputMBps = 200,

    [ValidateRange(1, 50)]
    [int]$ThrottleLimit = 10,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Write-Verbose "Get-AzAdeMigrationPlan v1.5.0"

$requiredCommands = @(
    "Get-AzContext", "Set-AzContext", "Connect-AzAccount",
    "Get-AzVM", "Get-AzVMExtension", "Get-AzVMDiskEncryptionStatus", "Get-AzDisk",
    "Get-AzComputeResourceSku", "Get-AzProviderFeature", "Get-AzResourceGroup"
)
if ($ResourceGroupName -and $AllResourceGroups) {
    throw "Use either -ResourceGroupName or -AllResourceGroups, not both."
}
foreach ($command in $requiredCommands) {
    if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found. Install the Az PowerShell modules (Install-Module Az -Scope CurrentUser)."
    }
}

#region Helpers
function Get-OptionalPropertyValue {
    param($InputObject, [string]$PropertyName)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($PropertyName)) { return $InputObject[$PropertyName] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($property) { return $property.Value }
    return $null
}

function Get-ResourceGroupFromId {
    param([string]$ResourceId)
    if ($ResourceId -match '/resourceGroups/([^/]+)/') { return $Matches[1] }
    return $null
}

function Get-ResourceNameFromId {
    param([string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $null }
    return ($ResourceId.TrimEnd('/') -split '/')[-1]
}

function ConvertTo-HtmlText {
    param($Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Resolve-OutputFilePath {
    param([string]$Path, [string]$DefaultFileName)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path -Path (Get-Location).Path -ChildPath $DefaultFileName
    }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $resolved = Join-Path -Path $resolved -ChildPath $DefaultFileName
    }
    $parent = Split-Path -Path $resolved -Parent
    if ([string]::IsNullOrWhiteSpace($parent)) { $parent = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Output directory '$parent' does not exist."
    }
    return $resolved
}

function Test-IsEncryptedStatus {
    param($Status)
    return ([string]$Status) -in @("Encrypted", "EncryptionInProgress", "DecryptionInProgress", "VMRestartPending")
}

function Get-VmPowerStateText {
    param($VmStatus)
    $listState = [string](Get-OptionalPropertyValue -InputObject $VmStatus -PropertyName "PowerState")
    if ($listState) { return ($listState -replace '^(VM|PowerState/)\s*', '') }
    $statuses =  @(Get-OptionalPropertyValue -InputObject $VmStatus -PropertyName "Statuses")
    foreach ($status in $statuses) {
        $code = [string](Get-OptionalPropertyValue -InputObject $status -PropertyName "Code")
        if ($code -like "PowerState/*") { return $code.Substring(11) }
    }
    return "unknown"
}

function Get-EahSizeSupport {
    param([string]$Location, [string]$VmSize)
    $key = $Location.ToLowerInvariant()
    if (-not $script:SkuCache.ContainsKey($key)) {
        $map = @{}
        try {
            foreach ($sku in @(Get-AzComputeResourceSku -Location $Location -ErrorAction Stop | Where-Object { $_.ResourceType -eq "virtualMachines" })) {
                $cap = @($sku.Capabilities | Where-Object { $_.Name -eq "EncryptionAtHostSupported" } | Select-Object -First 1)
                $map[$sku.Name.ToLowerInvariant()] = if ($cap.Count -gt 0) { $cap[0].Value -eq "True" } else { $false }
            }
        }
        catch {
            Write-Warning "Could not read VM SKUs for '$Location': $($_.Exception.Message)"
        }
        $script:SkuCache[$key] = $map
    }
    $sizeKey = $VmSize.ToLowerInvariant()
    if ($script:SkuCache[$key].ContainsKey($sizeKey)) { return [bool]$script:SkuCache[$key][$sizeKey] }
    return $null
}
#endregion Helpers

$script:SkuCache = @{}
$startTime = (Get-Date).ToUniversalTime()
$timestamp = $startTime.ToString("yyyyMMdd-HHmmss")
$results = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[object]

try {
    #region Sign-in (reuse existing Azure CLI or Az PowerShell session; never starts an interactive login)
    $loginHint = if ($TenantId) { "az login --tenant $TenantId" } else { "az login" }
    $usedCli = $false
    if (Get-Command -Name az -ErrorAction SilentlyContinue) {
        $tokenArguments = @("account", "get-access-token", "--output", "none", "--subscription", $SubscriptionId)
        $null = & az @tokenArguments 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Verbose "Using the existing Azure CLI session."
            $null = & az account set --subscription $SubscriptionId
            $account = (& az account show -o json) | ConvertFrom-Json
            $accessToken = & az account get-access-token --subscription $account.id --query accessToken -o tsv
            Connect-AzAccount -AccessToken $accessToken -AccountId $account.user.name -Tenant $account.tenantId -Subscription $account.id -ErrorAction Stop | Out-Null
            $usedCli = $true
        }
    }
    if (-not $usedCli) {
        $context = Get-AzContext
        if (-not $context -or -not $context.Account) {
            throw "No valid Azure CLI or Az PowerShell session was found. Run '$loginHint' or Connect-AzAccount and try again."
        }
        if (-not $context.Subscription -or $context.Subscription.Id -ne $SubscriptionId) {
            Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
        }
        Write-Verbose "Using the existing Az PowerShell session."
    }
    $context = Get-AzContext
    $subscriptionName = $context.Subscription.Name
    $tenantName = $context.Tenant.Id
    $signedInAs = $context.Account.Id
    #endregion Sign-in

    #region Subscription-level data
    Write-Verbose "Reading subscription '$subscriptionName' ($SubscriptionId)..."

    $featureState = "Unknown"
    try {
        $feature = Get-AzProviderFeature -ProviderNamespace "Microsoft.Compute" -FeatureName "EncryptionAtHost" -ErrorAction Stop
        $featureState = [string]$feature.RegistrationState
    }
    catch { Write-Warning "Could not read the EncryptionAtHost feature state: $($_.Exception.Message)" }

    #region Resource group scope
    $rgList = @(Get-AzResourceGroup -ErrorAction Stop | Sort-Object -Property ResourceGroupName)
    if ($ResourceGroupName) {
        $validated = @()
        $unknown = @()
        foreach ($rgName in $ResourceGroupName) {
            $match = $rgList | Where-Object { $_.ResourceGroupName -ieq $rgName } | Select-Object -First 1
            if ($match) { $validated += $match.ResourceGroupName } else { $unknown += $rgName }
        }
        if ($unknown.Count -gt 0) {
            throw "Resource group(s) not found in subscription '$subscriptionName': $($unknown -join ', ')."
        }
        $ResourceGroupName = @($validated | Select-Object -Unique)
    }
    elseif (-not $AllResourceGroups.IsPresent) {
        # Console redirection flags are unreliable in hosts such as VS Code, so the picker always tries
        # to prompt and only falls back to ALL when the host genuinely cannot read input.
        $readAnswer = {
            param($prompt)
            try { $value = Read-Host $prompt }
            catch { throw [System.OperationCanceledException]::new('NoInteractiveInput') }
            if ($null -eq $value) { throw [System.OperationCanceledException]::new('NoInteractiveInput') }
            return $value
        }
        if ($rgList.Count -eq 0) {
            Write-Warning "No resource groups were found in subscription '$subscriptionName'."
        }
        else {
            $vmCountByRg = @{}
            foreach ($v in @(Get-AzVM -ErrorAction Stop)) {
                $key = $v.ResourceGroupName.ToLowerInvariant()
                $vmCountByRg[$key] = 1 + [int]$vmCountByRg[$key]
            }
            $totalVms = [int](($vmCountByRg.Values | Measure-Object -Sum).Sum)
            $rgCount = { param($rg) [int]$vmCountByRg[$rg.ResourceGroupName.ToLowerInvariant()] }
            # Resource groups with the most VMs first, so the most relevant ones appear in the first page.
            $rankedGroups = @($rgList | Sort-Object -Property @{ Expression = { & $rgCount $_ }; Descending = $true }, ResourceGroupName)
            $pageSize = 10

            $showList = {
                param($groups, $title, $offset)
                $page = @($groups | Select-Object -Skip $offset -First $pageSize)
                Write-Host ""
                Write-Host $title -ForegroundColor Cyan
                Write-Host ("  {0,3}  {1}  ({2} VMs in {3} resource groups)" -f "A", "ALL resource groups", $totalVms, $rgList.Count) -ForegroundColor Yellow
                for ($i = 0; $i -lt $page.Count; $i++) {
                    Write-Host ("  {0,3}  {1}  ({2} VMs, {3})" -f ($i + 1), $page[$i].ResourceGroupName, (& $rgCount $page[$i]), $page[$i].Location)
                }
                $remaining = $groups.Count - $offset - $page.Count
                if ($remaining -gt 0) { Write-Host ("        ... {0} more not shown. Type M for the next {1}, or type a name to search." -f $remaining, $pageSize) -ForegroundColor DarkGray }
                return , $page
            }

            $listSource = $rankedGroups
            $listTitle = "Select the resource group to scan (top $pageSize by VM count):"
            $offset = 0
            $currentPage = & $showList $listSource $listTitle $offset
            $selection = $null
            try {
            while (-not $selection) {
                $answer = & $readAnswer "Enter A for ALL, a number from the list, or type a resource group name (comma-separate for several)"
                if ([string]::IsNullOrWhiteSpace($answer)) { continue }
                $answer = $answer.Trim()

                if ($answer -in @('a', 'all', '*', '0')) { $selection = @('*'); break }
                if ($answer -ieq 'm') {
                    $offset += $pageSize
                    if ($offset -ge $listSource.Count) { $offset = 0 }
                    $currentPage = & $showList $listSource $listTitle $offset
                    continue
                }

                $tokens = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $picked = @()
                $invalid = @()
                foreach ($token in $tokens) {
                    $number = 0
                    if ([int]::TryParse($token, [ref]$number) -and $number -ge 1 -and $number -le $currentPage.Count) {
                        $picked += $currentPage[$number - 1].ResourceGroupName
                        continue
                    }
                    $match = $rgList | Where-Object { $_.ResourceGroupName -ieq $token } | Select-Object -First 1
                    if ($match) { $picked += $match.ResourceGroupName } else { $invalid += $token }
                }

                if ($invalid.Count -eq 0) { $selection = @($picked | Select-Object -Unique); break }

                # A single unrecognized entry is treated as a search term over all resource group names.
                if ($tokens.Count -eq 1) {
                    $term = $tokens[0]
                    $found = @($rankedGroups | Where-Object { $_.ResourceGroupName -like "*$term*" })
                    if ($found.Count -eq 1) {
                        $confirm = & $readAnswer "Did you mean '$($found[0].ResourceGroupName)'? [Y/n]"
                        if ($confirm -notmatch '^(n|no)$') { $selection = @($found[0].ResourceGroupName); break }
                        continue
                    }
                    if ($found.Count -gt 1) {
                        $listSource = $found
                        $listTitle = "Resource groups matching '$term' ($($found.Count) found):"
                        $offset = 0
                        $currentPage = & $showList $listSource $listTitle $offset
                        continue
                    }
                }
                Write-Host "Not recognized: $($invalid -join ', '). Try again, type part of a name to search, or A for ALL." -ForegroundColor Red
            }
            }
            catch [System.OperationCanceledException] {
                Write-Host "This session cannot read typed input, so ALL resource groups will be scanned. Use -ResourceGroupName <name> or -AllResourceGroups to choose the scope explicitly." -ForegroundColor Yellow
                $selection = @('*')
            }
            if ($selection -ne '*') { $ResourceGroupName = $selection }
        }
    }
    if ($ResourceGroupName) {
        Write-Verbose "Scanning resource group(s): $($ResourceGroupName -join ', ')"
    }
    else {
        Write-Verbose "Scanning ALL resource groups in the subscription."
    }
    #endregion Resource group scope

    $toFileNamePart = {
        param([string]$Text)
        $invalidChars = [IO.Path]::GetInvalidFileNameChars()
        $clean = -join ($Text.ToCharArray() | ForEach-Object { if ($invalidChars -contains $_ -or $_ -eq ' ') { '-' } else { $_ } })
        ($clean -replace '-{2,}', '-').Trim('-', '.')
    }
    $subPart = & $toFileNamePart $subscriptionName
    if (-not $subPart) { $subPart = $SubscriptionId }
    if ($ResourceGroupName) {
        $rgPart = & $toFileNamePart ($ResourceGroupName -join '_')
        if ($rgPart.Length -gt 60) { $rgPart = "$(@($ResourceGroupName).Count)RGs" }
    }
    else {
        $rgPart = 'AllRGs'
    }
    $baseName = "AdeMigrationPlan-$subPart-$rgPart-$timestamp"
    $reportFile = Resolve-OutputFilePath -Path $OutputPath -DefaultFileName "$baseName.html"
    $csvFile = $null
    if ($CsvPath) { $csvFile = Resolve-OutputFilePath -Path $CsvPath -DefaultFileName "$baseName.csv" }

    $vms = @()
    $vmStatusById = @{}
    if ($ResourceGroupName) {
        foreach ($rg in $ResourceGroupName) {
            $vms += @(Get-AzVM -ResourceGroupName $rg -ErrorAction Stop)
            foreach ($s in @(Get-AzVM -ResourceGroupName $rg -Status -ErrorAction Stop)) { $vmStatusById[$s.Id.ToLowerInvariant()] = $s }
        }
    }
    else {
        $vms = @(Get-AzVM -ErrorAction Stop)
        foreach ($s in @(Get-AzVM -Status -ErrorAction Stop)) { $vmStatusById[$s.Id.ToLowerInvariant()] = $s }
    }

    $diskById = @{}
    foreach ($d in @(Get-AzDisk -ErrorAction Stop)) { $diskById[$d.Id.ToLowerInvariant()] = $d }

    $backupAvailable = (-not $SkipBackupCheck) -and [bool](Get-Command -Name Get-AzRecoveryServicesBackupStatus -ErrorAction SilentlyContinue)
    $backupProviderMissing = $false
    if (-not $SkipBackupCheck -and -not $backupAvailable) {
        Write-Warning "Az.RecoveryServices is not installed; backup protection will be reported as Unknown."
    }
    if ($backupAvailable) {
        # Without the Microsoft.RecoveryServices provider no vault can exist, so no VM can be protected by Azure Backup.
        $rsProvider = Get-AzResourceProvider -ProviderNamespace Microsoft.RecoveryServices -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($rsProvider -and $rsProvider.RegistrationState -ne 'Registered') {
            $backupAvailable = $false
            $backupProviderMissing = $true
            Write-Verbose "Microsoft.RecoveryServices provider is not registered - no VM is protected by Azure Backup; skipping per-VM backup lookup."
        }
    }
    Write-Verbose ("Found {0} VM(s). Analyzing..." -f $vms.Count)
    #endregion Subscription-level data

    #region Parallel per-VM collection (read-only)
    foreach ($location in @($vms | ForEach-Object { $_.Location } | Sort-Object -Unique)) {
        Write-Verbose "Reading VM size capabilities for '$location'..."
        $null = Get-EahSizeSupport -Location $location -VmSize "none"
    }

    $workerScript = {
        param([string]$ResourceGroup, [string]$VmName, [string]$VmId, $AzContext, [bool]$CheckBackup)
        $ErrorActionPreference = "Stop"
        $output = @{ Id = $VmId; Extensions = @(); OsVolumeEncrypted = $null; DataVolumesEncrypted = $null; BackedUp = $null; BackupError = $null; Errors = @() }
        $modules = @('Az.Accounts', 'Az.Compute')
        if ($CheckBackup) { $modules += 'Az.RecoveryServices' }
        # Concurrent Import-Module calls across runspaces can intermittently fail ("Collection was modified"), so retry with jitter.
        $maxAttempts = 5
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                Import-Module $modules -ErrorAction Stop -WarningAction SilentlyContinue
                break
            }
            catch {
                if ($attempt -eq $maxAttempts) {
                    $output.Errors += "Module import failed after $maxAttempts attempts: $($_.Exception.Message)"
                    return $output
                }
                Start-Sleep -Milliseconds (Get-Random -Minimum 200 -Maximum 1500)
            }
        }
        try {
            $output.Extensions = @(Get-AzVMExtension -ResourceGroupName $ResourceGroup -VMName $VmName -DefaultProfile $AzContext -ErrorAction Stop | ForEach-Object {
                    @{
                        Name           = [string]$_.Name
                        Publisher      = [string]$_.Publisher
                        Type           = [string]$_.ExtensionType
                        Version        = [string]$_.TypeHandlerVersion
                        PublicSettings = [string]$_.PublicSettings
                    }
                })
        }
        catch { $output.Errors += "Extension read failed: $($_.Exception.Message)" }
        try {
            $enc = Get-AzVMDiskEncryptionStatus -ResourceGroupName $ResourceGroup -VMName $VmName -DefaultProfile $AzContext -ErrorAction Stop
            $output.OsVolumeEncrypted = [string]$enc.OsVolumeEncrypted
            $output.DataVolumesEncrypted = [string]$enc.DataVolumesEncrypted
        }
        catch { $output.Errors += "Encryption status read failed: $($_.Exception.Message)" }
        if ($CheckBackup) {
            try {
                $backup = Get-AzRecoveryServicesBackupStatus -ResourceGroupName $ResourceGroup -Name $VmName -Type AzureVM -DefaultProfile $AzContext -ErrorAction Stop
                $output.BackedUp = [bool]$backup.BackedUp
            }
            catch {
                $msg = $_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($msg)) { $msg = "$($_.Exception.GetType().Name) (no details returned)" }
                $output.BackupError = "Backup status could not be read: $msg"
            }
        }
        return $output
    }

    $collected = @{}
    $pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit)
    $pool.Open()
    $jobs = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($vm in $vms) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript($workerScript.ToString()).AddArgument($vm.ResourceGroupName).AddArgument($vm.Name).AddArgument($vm.Id).AddArgument($context).AddArgument($backupAvailable)
            $jobs.Add([pscustomobject]@{ Vm = $vm; PowerShell = $ps; Handle = $ps.BeginInvoke() })
        }
        $done = 0
        foreach ($job in $jobs) {
            $percent = if ($jobs.Count) { [int](($done / $jobs.Count) * 100) } else { 100 }
            Write-Progress -Activity "Analyzing VMs ($ThrottleLimit in parallel)" -Status "$done of $($jobs.Count) complete" -PercentComplete $percent
            try {
                $out = @($job.PowerShell.EndInvoke($job.Handle))
                if ($out.Count -gt 0 -and $out[-1] -is [System.Collections.IDictionary]) { $collected[$job.Vm.Id.ToLowerInvariant()] = $out[-1] }
                else { $collected[$job.Vm.Id.ToLowerInvariant()] = @{ Extensions = @(); Errors = @("Worker returned no data.") } }
            }
            catch {
                $collected[$job.Vm.Id.ToLowerInvariant()] = @{ Extensions = @(); Errors = @("Worker failed: $($_.Exception.Message)") }
            }
            finally { $job.PowerShell.Dispose() }
            $done++
        }
        Write-Progress -Activity "Analyzing VMs ($ThrottleLimit in parallel)" -Completed
    }
    finally {
        $pool.Close()
        $pool.Dispose()
    }
    #endregion Parallel per-VM collection

    #region Classification
    $overheadHours = @{
        WindowsOsOnly = 2; WindowsOsData = 3; LinuxDataOnly = 3; LinuxOsRebuild = 8
        AvdSessionHost = 4; Manual = 4; AlreadyEah = 0; NoAde = 0
    }
    $adeTypes = @("AzureDiskEncryption", "AzureDiskEncryptionForLinux")

    foreach ($vm in $vms) {
        $id = $vm.Id.ToLowerInvariant()
        $data = $collected[$id]
        $osType = [string]$vm.StorageProfile.OsDisk.OsType
        $blockers = New-Object System.Collections.Generic.List[string]
        $warnings = New-Object System.Collections.Generic.List[string]
        foreach ($e in @($data.Errors)) { if ($e) { $warnings.Add($e); $failures.Add([pscustomobject]@{ VmName = $vm.Name; ResourceGroup = $vm.ResourceGroupName; Error = $e }) } }
        $backedUp = if ($backupProviderMissing) { $false } elseif ($data.ContainsKey('BackedUp')) { $data.BackedUp } else { $null }
        if ($data.ContainsKey('BackupError') -and $data.BackupError) { $warnings.Add($data.BackupError) }

        $extensions = @($data.Extensions)
        $adeExt = @($extensions | Where-Object { $_.Type -in $adeTypes } | Select-Object -First 1)
        $adeSettings = $null
        if ($adeExt.Count -gt 0 -and $adeExt[0].PublicSettings) {
            try { $adeSettings = $adeExt[0].PublicSettings | ConvertFrom-Json } catch { $adeSettings = $null }
        }
        $adeVersion = if ($adeExt.Count -gt 0) { $adeExt[0].Version } else { "" }

        $keyVaults = New-Object System.Collections.Generic.List[string]
        foreach ($prop in @("KeyVaultResourceId", "KekVaultResourceId")) {
            $kv = [string](Get-OptionalPropertyValue -InputObject $adeSettings -PropertyName $prop)
            if ($kv) { $keyVaults.Add((Get-ResourceNameFromId $kv)) }
        }
        foreach ($prop in @("KeyVaultURL", "KeyEncryptionKeyURL")) {
            $url = [string](Get-OptionalPropertyValue -InputObject $adeSettings -PropertyName $prop)
            if ($url -match '^https://([^.]+)\.') { $keyVaults.Add($Matches[1]) }
        }

        $unmanaged = $null -ne $vm.StorageProfile.OsDisk.Vhd
        $diskIds = @()
        if ($vm.StorageProfile.OsDisk.ManagedDisk) { $diskIds += $vm.StorageProfile.OsDisk.ManagedDisk.Id }
        foreach ($dd in @($vm.StorageProfile.DataDisks)) { if ($dd.ManagedDisk) { $diskIds += $dd.ManagedDisk.Id } }
        $totalGiB = 0; $osDiskFlag = $false; $dataDiskFlag = $false
        foreach ($diskId in $diskIds) {
            $disk = $diskById[$diskId.ToLowerInvariant()]
            if (-not $disk) { continue }
            $totalGiB += [int]$disk.DiskSizeGB
            $esc = $disk.EncryptionSettingsCollection
            if ($esc -and $esc.Enabled) {
                if ($diskId -eq $diskIds[0]) { $osDiskFlag = $true } else { $dataDiskFlag = $true }
                foreach ($es in @($esc.EncryptionSettings)) {
                    $vaultId = $es.DiskEncryptionKey.SourceVault.Id
                    if ($vaultId) { $keyVaults.Add((Get-ResourceNameFromId $vaultId)) }
                }
            }
        }
        if ($unmanaged) {
            $totalGiB = [int]$vm.StorageProfile.OsDisk.DiskSizeGB + (@($vm.StorageProfile.DataDisks) | Measure-Object -Property DiskSizeGB -Sum).Sum
        }
        $diskCount = 1 + @($vm.StorageProfile.DataDisks).Count

        $osEnc = (Test-IsEncryptedStatus $data.OsVolumeEncrypted) -or $osDiskFlag
        $dataEnc = (Test-IsEncryptedStatus $data.DataVolumesEncrypted) -or $dataDiskFlag
        $volumeType = [string](Get-OptionalPropertyValue -InputObject $adeSettings -PropertyName "VolumeType")
        if ($adeExt.Count -gt 0 -and -not $osEnc -and -not $dataEnc) {
            if ($volumeType -match '^(All|OS)$') { $osEnc = $true }
            if ($volumeType -match '^(All|Data)$') { $dataEnc = $true }
        }
        $adeAny = ($adeExt.Count -gt 0) -or $osEnc -or $dataEnc
        $inProgress = @($data.OsVolumeEncrypted, $data.DataVolumesEncrypted) -match 'InProgress|RestartPending'
        $eah = [bool](Get-OptionalPropertyValue -InputObject $vm.SecurityProfile -PropertyName "EncryptionAtHost")
        $domainJoined = [bool]@($extensions | Where-Object { $_.Type -eq "JsonADDomainExtension" }).Count
        $aadLogin = [bool]@($extensions | Where-Object { $_.Type -in @("AADLoginForWindows", "AADSSHLoginForLinux") }).Count
        $tagText = (@($vm.Tags.Keys) + @($vm.Tags.Values)) -join " "
        $avd = ($tagText -match 'hostpool') -or [bool]@($extensions | Where-Object { $_.Type -eq "DSC" -and $_.Name -match 'DSC|AVD|AddSessionHost' }).Count
        $sizeSupport = Get-EahSizeSupport -Location $vm.Location -VmSize $vm.HardwareProfile.VmSize
        $powerState = Get-VmPowerStateText $vmStatusById[$id]

        $path = if ($eah -and -not $adeAny) { "AlreadyEah" }
        elseif (-not $adeAny) { "NoAde" }
        elseif ($unmanaged -or $inProgress) { "Manual" }
        elseif ($avd) { "AvdSessionHost" }
        elseif ($osType -eq "Windows") { if ($dataEnc) { "WindowsOsData" } else { "WindowsOsOnly" } }
        elseif ($osEnc) { "LinuxOsRebuild" }
        else { "LinuxDataOnly" }

        if ($path -eq "NoAde" -and -not $IncludeNonAdeVms) { continue }

        if ($unmanaged) { $blockers.Add("Uses unmanaged (VHD) disks. Convert to managed disks (ConvertTo-AzVMManagedDisk) before migrating.") }
        if ($inProgress) { $blockers.Add("ADE operation in progress (OS: $($data.OsVolumeEncrypted); Data: $($data.DataVolumesEncrypted)). Wait for it to finish, then re-run this analysis.") }
        if ($adeAny -and $sizeSupport -eq $false) { $blockers.Add("VM size $($vm.HardwareProfile.VmSize) does not support encryption at host. Choose a supported size for the new VM.") }
        if ($adeAny -and $null -eq $sizeSupport) { $warnings.Add("Could not confirm encryption-at-host support for size $($vm.HardwareProfile.VmSize) in $($vm.Location).") }
        if ($eah -and $adeAny) { $warnings.Add("EncryptionAtHost is set but ADE is also detected. Review manually.") }
        if ($osType -eq "Windows" -and $dataEnc -and -not $osEnc) { $warnings.Add("Only data volumes report as encrypted. Confirm with manage-bde -status before disabling ADE.") }
        if ($adeVersion -match '^(0\.|1\.1)') { $warnings.Add("Dual-pass ADE (version $adeVersion, uses Microsoft Entra app). Disable and remove it the same way; also clean up the Entra app registration afterwards.") }
        if ($domainJoined) { $warnings.Add("Domain-joined (JsonADDomainExtension). Plan unjoin/rejoin; the new VM gets a new identity.") }
        if ($aadLogin) { $warnings.Add("Microsoft Entra login extension installed. Reinstall it and reassign VM login roles on the new VM.") }
        if ($backedUp -eq $true) { $warnings.Add("Protected by Azure Backup. Enable backup on the new VM; keep old restore points until no longer needed.") }
        if ($adeAny -and $path -in @("WindowsOsOnly", "WindowsOsData", "LinuxDataOnly") -and $powerState -ne "running") { $warnings.Add("VM is '$powerState'. It must be running to disable ADE.") }
        $otherExt = @($extensions | Where-Object { $_.Type -notin $adeTypes } | ForEach-Object { $_.Name })
        if ($adeAny -and $otherExt.Count -gt 0) { $warnings.Add("Extensions to reinstall on the new VM: $($otherExt -join ', ').") }

        $copyMinutes = [math]::Ceiling(($totalGiB * 1024) / $CopyThroughputMBps / 60)
        $effort = if ($path -in @("AlreadyEah", "NoAde")) { 0 } else { [math]::Round($overheadHours[$path] + ($copyMinutes / 60), 1) }
        $scope = if ($osEnc -and $dataEnc) { "OS + Data" } elseif ($osEnc) { "OS" } elseif ($dataEnc) { "Data" } else { "None" }

        $results.Add([pscustomobject]@{
                VmName               = $vm.Name
                ResourceGroup        = $vm.ResourceGroupName
                Location             = $vm.Location
                OsType               = $osType
                VmSize               = $vm.HardwareProfile.VmSize
                PowerState           = $powerState
                AdeExtension         = if ($adeExt.Count -gt 0) { $adeExt[0].Type } else { "" }
                AdeVersion           = $adeVersion
                EncryptedScope       = $scope
                MigrationPath        = $path
                Supported            = ($blockers.Count -eq 0 -and $path -ne "Manual")
                SizeSupportsEah      = $sizeSupport
                DomainJoined         = $domainJoined
                AvdSessionHost       = $avd
                BackupProtected      = $backedUp
                DiskCount            = $diskCount
                TotalDiskGiB         = $totalGiB
                EstimatedCopyMinutes = if ($path -in @("AlreadyEah", "NoAde")) { 0 } else { $copyMinutes }
                EffortHours          = $effort
                KeyVaults            = @($keyVaults | Where-Object { $_ } | Sort-Object -Unique)
                Blockers             = @($blockers)
                Warnings             = @($warnings)
                AnalyzedUtc          = (Get-Date).ToUniversalTime().ToString("o")
            })
    }
    #endregion Classification

    #region Migration path catalog (steps based on the Microsoft Learn article)
    $copyDiskCode = @'
# Repeat for the OS disk and every data disk of the VM.
$src  = Get-AzDisk -ResourceGroupName "<rg>" -DiskName "<disk>"
$size = $src.DiskSizeBytes + 512
$cfg  = New-AzDiskConfig -Location $src.Location -CreateOption Upload -UploadSizeInBytes $size `
          -SkuName $src.Sku.Name -Zone $src.Zones
# OS disk only: add  -OsType $src.OsType -HyperVGeneration $src.HyperVGeneration
$dst  = New-AzDisk -ResourceGroupName "<rg>" -DiskName "<disk>-eah" -Disk $cfg
$srcSas = Grant-AzDiskAccess -ResourceGroupName "<rg>" -DiskName $src.Name -DurationInSecond 86400 -Access Read
$dstSas = Grant-AzDiskAccess -ResourceGroupName "<rg>" -DiskName $dst.Name -DurationInSecond 86400 -Access Write
azcopy copy $srcSas.AccessSAS $dstSas.AccessSAS --blob-type PageBlob
Revoke-AzDiskAccess -ResourceGroupName "<rg>" -DiskName $src.Name
Revoke-AzDiskAccess -ResourceGroupName "<rg>" -DiskName $dst.Name
'@
    $newVmCode = @'
Stop-AzVM -ResourceGroupName "<rg>" -Name "<vm>" -Force      # stop and deallocate the original VM
$osDisk = Get-AzDisk -ResourceGroupName "<rg>" -DiskName "<osdisk>-eah"
$vmCfg  = New-AzVMConfig -VMName "<vm>-new" -VMSize "<size>" -EncryptionAtHost $true
$vmCfg  = Set-AzVMOSDisk -VM $vmCfg -ManagedDiskId $osDisk.Id -CreateOption Attach -Windows   # or -Linux
$vmCfg  = Add-AzVMDataDisk -VM $vmCfg -ManagedDiskId (Get-AzDisk -ResourceGroupName "<rg>" -DiskName "<data>-eah").Id -Lun 0 -CreateOption Attach
$vmCfg  = Add-AzVMNetworkInterface -VM $vmCfg -Id "<nic resource id>"   # reuse or create a NIC
New-AzVM -ResourceGroupName "<rg>" -Location "<location>" -VM $vmCfg
'@
    $verifyCode = @'
(Get-AzVM -ResourceGroupName "<rg>" -Name "<vm>-new").SecurityProfile.EncryptionAtHost   # must be True
'@
    $stepCopy = [pscustomobject]@{ Title = "Copy every disk to a new managed disk"; Text = "Disks that were ever encrypted with ADE keep a hidden encryption flag, so they cannot simply be reattached. Create an empty upload disk of the same size (+512 bytes) and copy the data with AzCopy. Time this step: it is usually the longest part of the outage."; Code = $copyDiskCode }
    $stepNewVm = [pscustomobject]@{ Title = "Create the new VM with encryption at host"; Text = "Deallocate the original VM, then build a new VM from the copied disks with -EncryptionAtHost `$true. Reuse the NIC/IP (detach it from the old VM first) or create new ones, and keep the same size family if it supports encryption at host."; Code = $newVmCode }
    $stepVerify = [pscustomobject]@{ Title = "Verify and restore configuration"; Text = "Confirm EncryptionAtHost is True, sign in and check the application, reinstall VM extensions, re-enable Azure Backup, monitoring agents, diagnostics and any role assignments / managed identities."; Code = $verifyCode }
    $stepBackup = [pscustomobject]@{ Title = "Back up and schedule a maintenance window"; Text = "Take a backup or snapshot of all disks, record the VM configuration (size, NICs, IPs, tags, extensions, identities, availability set/zone) and agree a downtime window with the application owner."; Code = $null }

    $pathCatalog = [ordered]@{
        WindowsOsOnly  = [pscustomobject]@{ Name = "Windows - OS volume encrypted"; Difficulty = "Low"; Downtime = "Yes (disk copy duration + ~1 h)"; Description = "Windows VM where ADE encrypts only the OS volume. Disable ADE, copy the disks and recreate the VM with encryption at host."
            Steps = @($stepBackup,
                [pscustomobject]@{ Title = "Disable Azure Disk Encryption"; Text = "With the VM running, disable ADE and remove the extension. BitLocker decrypts the volume inside the guest."; Code = "Disable-AzVMDiskEncryption -ResourceGroupName `"<rg>`" -VMName `"<vm>`" -VolumeType All`nRemove-AzVMDiskEncryptionExtension -ResourceGroupName `"<rg>`" -VMName `"<vm>`"" },
                [pscustomobject]@{ Title = "Confirm decryption completed"; Text = "Inside the VM, wait until every volume shows 'Fully Decrypted' and 'Protection Off'."; Code = "manage-bde -status" },
                $stepCopy, $stepNewVm, $stepVerify) }
        WindowsOsData  = [pscustomobject]@{ Name = "Windows - OS and data volumes encrypted"; Difficulty = "Medium"; Downtime = "Yes (disk copy duration + ~1-2 h)"; Description = "Windows VM where ADE encrypts the OS and data volumes. Same as the OS-only path, but every data disk must be decrypted and copied too."
            Steps = @($stepBackup,
                [pscustomobject]@{ Title = "Disable Azure Disk Encryption on all volumes"; Text = "With the VM running, disable ADE for all volumes and remove the extension."; Code = "Disable-AzVMDiskEncryption -ResourceGroupName `"<rg>`" -VMName `"<vm>`" -VolumeType All`nRemove-AzVMDiskEncryptionExtension -ResourceGroupName `"<rg>`" -VMName `"<vm>`"" },
                [pscustomobject]@{ Title = "Confirm decryption completed on every volume"; Text = "Inside the VM, check the OS and each data volume. Large data volumes can take hours to decrypt."; Code = "manage-bde -status" },
                $stepCopy, $stepNewVm,
                [pscustomobject]@{ Title = "Check drive letters"; Text = "On the new VM, confirm data disks are online and have the same drive letters (Disk Management or Get-Disk / Set-Partition)."; Code = $null },
                $stepVerify) }
        LinuxDataOnly  = [pscustomobject]@{ Name = "Linux - data volumes only encrypted"; Difficulty = "Medium"; Downtime = "Yes (disk copy duration + ~1-2 h)"; Description = "Linux VM where ADE encrypts only data volumes. ADE can be disabled for data volumes, then the disks are copied and the VM recreated."
            Steps = @($stepBackup,
                [pscustomobject]@{ Title = "Disable Azure Disk Encryption for data volumes"; Text = "Disabling is only supported for data volumes on Linux. Remove the extension afterwards."; Code = "Disable-AzVMDiskEncryption -ResourceGroupName `"<rg>`" -VMName `"<vm>`" -VolumeType Data`nRemove-AzVMDiskEncryptionExtension -ResourceGroupName `"<rg>`" -VMName `"<vm>`"" },
                [pscustomobject]@{ Title = "Confirm decryption completed"; Text = "Inside the VM, confirm no dm-crypt mappings remain for the data volumes."; Code = "sudo cryptsetup status <mapper-name>`nlsblk -o NAME,TYPE,FSTYPE,MOUNTPOINT" },
                $stepCopy, $stepNewVm,
                [pscustomobject]@{ Title = "Fix /etc/fstab mounts"; Text = "Device names and mapper paths change after decryption. Update /etc/fstab to use filesystem UUIDs (with nofail) and test the mounts before rebooting."; Code = "sudo blkid`nsudo vi /etc/fstab     # UUID=<uuid> /data ext4 defaults,nofail 0 2`nsudo mount -a" },
                $stepVerify) }
        LinuxOsRebuild = [pscustomobject]@{ Name = "Linux - OS volume encrypted (rebuild)"; Difficulty = "High"; Downtime = "Yes (application cut-over)"; Description = "Linux VM with an ADE-encrypted OS volume. ADE cannot be disabled for a Linux OS volume, so a new VM with encryption at host must be built and the application/data migrated."
            Steps = @($stepBackup,
                [pscustomobject]@{ Title = "Build a new VM with encryption at host"; Text = "Deploy a fresh VM from a marketplace or custom image with -EncryptionAtHost `$true, the same distribution/version and a supported size."; Code = "`$vmCfg = New-AzVMConfig -VMName `"<vm>-new`" -VMSize `"<size>`" -EncryptionAtHost `$true`n# ...set image, credentials and NIC, then New-AzVM" },
                [pscustomobject]@{ Title = "Reinstall and configure the application"; Text = "Install packages, configuration, users, certificates and services on the new VM (ideally with your configuration-management tooling)."; Code = $null },
                [pscustomobject]@{ Title = "Migrate the data"; Text = "Attach new empty data disks and copy the data from the old VM over the network, or restore it from backup. Data volumes that are only data-encrypted can alternatively be decrypted and copied as in the Linux data-only path."; Code = "rsync -aHAXv --progress /data/ <user>@<new-vm>:/data/" },
                [pscustomobject]@{ Title = "Cut over"; Text = "Stop the application on the old VM, do a final rsync, switch DNS / load balancer / IP to the new VM and test."; Code = $null },
                $stepVerify) }
        AvdSessionHost = [pscustomobject]@{ Name = "Azure Virtual Desktop session host"; Difficulty = "Medium"; Downtime = "No (rolling replacement)"; Description = "AVD session hosts are normally stateless. Replace them with new hosts created with encryption at host instead of converting each VM."
            Steps = @(
                [pscustomobject]@{ Title = "Prepare the golden image / host pool template"; Text = "Make sure the image and the host pool session host configuration deploy VMs with encryption at host enabled and a supported size."; Code = $null },
                [pscustomobject]@{ Title = "Add new session hosts"; Text = "Deploy new session hosts with encryption at host and register them in the same host pool."; Code = $null },
                [pscustomobject]@{ Title = "Validate user profiles"; Text = "Confirm FSLogix profile containers and applications work on the new hosts."; Code = $null },
                [pscustomobject]@{ Title = "Drain and remove the old hosts"; Text = "Turn on drain mode for the ADE hosts, wait for sessions to end, remove them from the host pool and delete the VMs and disks."; Code = "Update-AzWvdSessionHost -ResourceGroupName `"<rg>`" -HostPoolName `"<pool>`" -Name `"<host fqdn>`" -AllowNewSession:`$false" }) }
        Manual         = [pscustomobject]@{ Name = "Manual review required"; Difficulty = "High"; Downtime = "Depends"; Description = "The VM has a condition that blocks the standard paths (for example unmanaged disks, an ADE operation in progress or data that could not be read). Resolve the blockers listed for the VM, then re-run this analysis."
            Steps = @(
                [pscustomobject]@{ Title = "Resolve the blockers"; Text = "Review the blockers and warnings for the VM in this report (for example convert unmanaged disks to managed disks with ConvertTo-AzVMManagedDisk, or wait for the ADE operation to finish)."; Code = $null },
                [pscustomobject]@{ Title = "Re-run the analysis"; Text = "Run this script again so the VM is classified into a standard migration path."; Code = $null }) }
        AlreadyEah     = [pscustomobject]@{ Name = "Already using encryption at host"; Difficulty = "None"; Downtime = "No"; Description = "The VM already has encryption at host enabled and no ADE extension. No migration needed."; Steps = @() }
        NoAde          = [pscustomobject]@{ Name = "Not using Azure Disk Encryption"; Difficulty = "None"; Downtime = "Optional"; Description = "The VM does not use ADE. No migration is required; you can optionally enable encryption at host (requires a deallocation)."
            Steps = @([pscustomobject]@{ Title = "Optional: enable encryption at host"; Text = "Deallocate the VM, enable the setting and start it again."; Code = "Stop-AzVM -ResourceGroupName `"<rg>`" -Name `"<vm>`" -Force`n`$vm = Get-AzVM -ResourceGroupName `"<rg>`" -Name `"<vm>`"`nUpdate-AzVM -ResourceGroupName `"<rg>`" -VM `$vm -EncryptionAtHost `$true`nStart-AzVM -ResourceGroupName `"<rg>`" -Name `"<vm>`"" }) }
    }
    #endregion Migration path catalog


    #region Build HTML report
    Write-Verbose "Building report..."

    $pathCounts = [ordered]@{}
    foreach ($key in $pathCatalog.Keys) {
        $pathCounts[$key] = @($results | Where-Object { $_.MigrationPath -eq $key }).Count
    }
    $adeResults = @($results | Where-Object { $_.MigrationPath -notin @('AlreadyEah', 'NoAde') })
    $totalEffort = [math]::Round((($adeResults | Measure-Object -Property EffortHours -Sum).Sum + 0), 1)
    $totalCopyMinutes = [int](($adeResults | Measure-Object -Property EstimatedCopyMinutes -Sum).Sum + 0)
    $totalGiB = [int](($adeResults | Measure-Object -Property TotalDiskGiB -Sum).Sum + 0)
    $blockedCount = @($results | Where-Object { @($_.Blockers).Count -gt 0 }).Count
    $warningCount = @($results | Where-Object { @($_.Warnings).Count -gt 0 }).Count
    $sizeIssueCount = @($adeResults | Where-Object { $_.SizeSupportsEah -eq $false }).Count
    $domainCount = @($adeResults | Where-Object { $_.DomainJoined }).Count
    $allKeyVaults = @($results | ForEach-Object { @($_.KeyVaults) } | Where-Object { $_ } | Sort-Object -Unique)
    $usedPaths = @($pathCatalog.Keys | Where-Object { $pathCounts[$_] -gt 0 -and $_ -ne 'NoAde' -and $_ -ne 'AlreadyEah' })

    $sb = New-Object System.Text.StringBuilder
    function Add-Html { param([string]$Text) [void]$sb.AppendLine($Text) }
    function Get-HtmlList {
        param([object[]]$Items)
        $values = @($Items | Where-Object { $_ })
        if ($values.Count -eq 0) { return '&mdash;' }
        return (($values | ForEach-Object { ConvertTo-HtmlText ([string]$_) }) -join '<br>')
    }
    function Get-PathBadge {
        param([string]$Difficulty)
        $cls = switch ($Difficulty) { 'Low' { 'low' } 'Medium' { 'med' } 'High' { 'high' } default { 'none' } }
        return "<span class='badge $cls'>$(ConvertTo-HtmlText $Difficulty)</span>"
    }

    Add-Html '<!DOCTYPE html>'
    Add-Html '<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
    Add-Html "<title>ADE to encryption at host migration plan - $(ConvertTo-HtmlText $subscriptionName)</title>"
    Add-Html @'
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:0;color:#1b1b1b;background:#f5f6f8;line-height:1.45}
main{max-width:1200px;margin:0 auto;padding:24px 32px 64px;background:#fff}
h1{color:#0f4c81;margin-bottom:4px}h2{color:#0f4c81;border-bottom:2px solid #0f4c81;padding-bottom:4px;margin-top:40px}
h3{color:#244f73;margin-top:28px}.meta{color:#555;font-size:14px}
table{border-collapse:collapse;width:100%;margin:12px 0;font-size:13px}
th,td{border:1px solid #d0d7de;padding:6px 8px;text-align:left;vertical-align:top}
th{background:#eaf1f8}tr:nth-child(even) td{background:#fafbfc}
pre{background:#1e1e1e;color:#e6e6e6;padding:10px 12px;border-radius:6px;overflow-x:auto;font-size:12.5px}
code{font-family:Consolas,monospace}
.cards{display:flex;flex-wrap:wrap;gap:12px;margin:16px 0}
.card{flex:1 1 160px;border:1px solid #d0d7de;border-radius:8px;padding:12px 14px;background:#f8fbff}
.card .num{font-size:26px;font-weight:600;color:#0f4c81}.card .lbl{font-size:13px;color:#555}
.badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600}
.low{background:#dff6dd;color:#107c10}.med{background:#fff4ce;color:#8a6d00}.high{background:#fde7e9;color:#a4262c}.none{background:#eee;color:#555}
.note{border-left:4px solid #0f4c81;background:#eef5fb;padding:8px 12px;margin:12px 0}
.warn{border-left:4px solid #c19c00;background:#fff8e1;padding:8px 12px;margin:12px 0}
.bad{color:#a4262c;font-weight:600}.ok{color:#107c10;font-weight:600}
.toc ol{padding-left:20px}.toc li{margin:3px 0}
ol.steps>li{margin-bottom:14px}
.footer{margin-top:48px;font-size:12px;color:#777}
@media print{body{background:#fff}main{padding:0}pre{white-space:pre-wrap}}
</style></head><body><main>
'@
    Add-Html '<h1>Azure Disk Encryption to encryption at host &mdash; migration plan</h1>'
    Add-Html "<p class='meta'>Subscription: <b>$(ConvertTo-HtmlText $subscriptionName)</b> ($(ConvertTo-HtmlText $SubscriptionId))<br>Tenant: $(ConvertTo-HtmlText $tenantName) &middot; Generated by: $(ConvertTo-HtmlText $signedInAs) &middot; Generated (UTC): $(ConvertTo-HtmlText $startTime.ToString('yyyy-MM-dd HH:mm'))</p>"
    Add-Html "<div class='note'>This report is read-only analysis. No Azure resources were changed. Effort figures are planning estimates; validate them with a test migration.</div>"

    # Table of contents
    Add-Html "<nav class='toc'><h2 id='toc'>Table of contents</h2><ol>"
    Add-Html "<li><a href='#summary'>Executive summary</a></li>"
    Add-Html "<li><a href='#background'>Background: why migrate and how it works</a></li>"
    Add-Html "<li><a href='#prereq'>Prerequisites checklist</a></li>"
    Add-Html "<li><a href='#paths'>Migration paths overview</a></li>"
    Add-Html "<li><a href='#steps'>Detailed steps per migration path</a><ol>"
    foreach ($key in $usedPaths) { Add-Html "<li><a href='#path-$key'>$(ConvertTo-HtmlText $pathCatalog[$key].Name)</a></li>" }
    Add-Html "<li><a href='#domain'>Domain-joined VMs</a></li></ol></li>"
    Add-Html "<li><a href='#vms'>VMs by migration path</a></li>"
    Add-Html "<li><a href='#issues'>Blockers and warnings</a></li>"
    Add-Html "<li><a href='#cleanup'>Post-migration cleanup</a></li>"
    Add-Html "<li><a href='#automation'>Optional automation</a></li>"
    Add-Html "<li><a href='#planning'>Planning guidance</a></li>"
    Add-Html "<li><a href='#appendix'>Appendix: analysis details</a></li>"
    Add-Html "</ol></nav>"


    # Executive summary
    Add-Html "<h2 id='summary'>1. Executive summary</h2>"
    Add-Html "<div class='cards'>"
    Add-Html "<div class='card'><div class='num'>$($results.Count)</div><div class='lbl'>VMs analyzed</div></div>"
    Add-Html "<div class='card'><div class='num'>$($adeResults.Count)</div><div class='lbl'>VMs that need migration</div></div>"
    Add-Html "<div class='card'><div class='num'>$($pathCounts['AlreadyEah'])</div><div class='lbl'>Already on encryption at host</div></div>"
    Add-Html "<div class='card'><div class='num'>$totalEffort h</div><div class='lbl'>Estimated total effort</div></div>"
    Add-Html "<div class='card'><div class='num'>$totalGiB GiB</div><div class='lbl'>Disk capacity to copy</div></div>"
    Add-Html "<div class='card'><div class='num'>$blockedCount</div><div class='lbl'>VMs with blockers</div></div>"
    Add-Html "<div class='card'><div class='num'>$warningCount</div><div class='lbl'>VMs with warnings</div></div>"
    Add-Html "</div>"
    if ($adeResults.Count -eq 0) {
        Add-Html "<div class='note'><b>No VMs using Azure Disk Encryption were found in the analyzed scope.</b> No migration is required.</div>"
    }
    else {
        Add-Html "<p>$($adeResults.Count) VM(s) use Azure Disk Encryption and must be migrated before ADE retires on <b>September 15, 2028</b>. The table shows how they are distributed across migration paths.</p>"
    }
    Add-Html "<table><tr><th>Migration path</th><th>Difficulty</th><th>Downtime</th><th>VMs</th><th>Estimated effort (h)</th></tr>"
    foreach ($key in $pathCatalog.Keys) {
        if ($pathCounts[$key] -eq 0) { continue }
        $p = $pathCatalog[$key]
        $eff = [math]::Round(((@($results | Where-Object { $_.MigrationPath -eq $key }) | Measure-Object -Property EffortHours -Sum).Sum + 0), 1)
        Add-Html "<tr><td><a href='#vms-$key'>$(ConvertTo-HtmlText $p.Name)</a></td><td>$(Get-PathBadge $p.Difficulty)</td><td>$(ConvertTo-HtmlText $p.Downtime)</td><td>$($pathCounts[$key])</td><td>$eff</td></tr>"
    }
    Add-Html "</table>"
    $attention = New-Object System.Collections.Generic.List[string]
    if ($featureState -ne 'Registered') { $attention.Add("The <b>EncryptionAtHost</b> feature is not registered in this subscription (state: $(ConvertTo-HtmlText $featureState)). Register it before migrating.") }
    if ($sizeIssueCount -gt 0) { $attention.Add("$sizeIssueCount VM(s) use a size that does not support encryption at host. A resize is needed during migration.") }
    if ($domainCount -gt 0) { $attention.Add("$domainCount VM(s) appear to be domain-joined. See <a href='#domain'>Domain-joined VMs</a>.") }
    if ($pathCounts['LinuxOsRebuild'] -gt 0) { $attention.Add("$($pathCounts['LinuxOsRebuild']) Linux VM(s) have an encrypted OS volume and must be rebuilt. Plan these first; they need the most effort.") }
    if ($blockedCount -gt 0) { $attention.Add("$blockedCount VM(s) have blockers. See <a href='#issues'>Blockers and warnings</a>.") }
    if ($failures.Count -gt 0) { $attention.Add("$($failures.Count) VM(s) could not be analyzed. See the <a href='#appendix'>appendix</a>.") }
    if ($attention.Count -gt 0) {
        Add-Html "<div class='warn'><b>Needs attention</b><ul>"
        foreach ($a in $attention) { Add-Html "<li>$a</li>" }
        Add-Html "</ul></div>"
    }

    # Background
    Add-Html "<h2 id='background'>2. Background: why migrate and how it works</h2>"
    Add-Html "<ul>"
    Add-Html "<li><b>Azure Disk Encryption (ADE) retires on September 15, 2028.</b> After that date, ADE-enabled VMs keep running, but ADE is no longer supported.</li>"
    Add-Html "<li><b>Encryption at host</b> encrypts temp disks, caches and OS/data disk data flows at the host with platform-managed or customer-managed keys. It needs no guest agent extension and no Key Vault access from the VM.</li>"
    Add-Html "<li><b>There is no in-place conversion.</b> A VM that ever used ADE keeps an internal encryption flag on its managed disks (UDE), so you cannot enable encryption at host on those disks. You must decrypt, <b>copy the disks to new managed disks</b>, and create a new VM.</li>"
    Add-Html "<li>On <b>Windows</b>, ADE can be disabled for OS and data volumes. On <b>Linux</b>, ADE can be disabled only for data volumes; a Linux VM with an encrypted OS volume must be rebuilt.</li>"
    Add-Html "<li>Every path needs <b>downtime</b> for the disk copy and VM recreation. The new VM gets new resource IDs; private IPs and NICs can be reused.</li>"
    Add-Html "</ul>"
    Add-Html "<p>Reference: <a href='https://learn.microsoft.com/azure/virtual-machines/disk-encryption-migrate'>Migrate from Azure Disk Encryption to encryption at host</a>.</p>"

    # Prerequisites
    Add-Html "<h2 id='prereq'>3. Prerequisites checklist</h2>"
    $featureCls = if ($featureState -eq 'Registered') { 'ok' } else { 'bad' }
    Add-Html "<table><tr><th>#</th><th>Prerequisite</th><th>Status in this subscription</th></tr>"
    Add-Html "<tr><td>1</td><td>Register the <code>EncryptionAtHost</code> feature for <code>Microsoft.Compute</code>.<pre><code>$(ConvertTo-HtmlText "Register-AzProviderFeature -FeatureName EncryptionAtHost -ProviderNamespace Microsoft.Compute`nGet-AzProviderFeature -FeatureName EncryptionAtHost -ProviderNamespace Microsoft.Compute")</code></pre></td><td class='$featureCls'>$(ConvertTo-HtmlText $featureState)</td></tr>"
    $sizeText = if ($sizeIssueCount -gt 0) { "<span class='bad'>$sizeIssueCount VM(s) need a different size</span>" } else { "<span class='ok'>No size issues detected</span>" }
    Add-Html "<tr><td>2</td><td>Each VM uses a size that supports encryption at host (<code>EncryptionAtHostSupported</code> capability).</td><td>$sizeText</td></tr>"
    $backupText = if ($SkipBackupCheck) { 'Not checked (-SkipBackupCheck)' } elseif ($backupProviderMissing) { 'No VM is protected by Azure Backup (Microsoft.RecoveryServices provider not registered) - take snapshots before migrating' } elseif (-not $backupAvailable) { 'Not checked (Az.RecoveryServices unavailable)' } else { "$(@($adeResults | Where-Object { $_.BackupProtected -eq $true }).Count) of $($adeResults.Count) VM(s) protected by Azure Backup" }
    Add-Html "<tr><td>3</td><td>Take a <b>backup or snapshot</b> of every VM before you start. Keep it until the new VM is validated.</td><td>$(ConvertTo-HtmlText $backupText)</td></tr>"
    Add-Html "<tr><td>4</td><td>You have permissions to create disks and VMs, and to change Key Vault properties (Contributor on the resource groups / Key Vault).</td><td>Check manually</td></tr>"
    Add-Html "<tr><td>5</td><td>Record the VM configuration: size, NICs, IPs, availability set/zone, tags, extensions, diagnostics, and role assignments for managed identities.</td><td>Check manually</td></tr>"
    Add-Html "<tr><td>6</td><td>Schedule a maintenance window per VM and inform the application owners.</td><td>See <a href='#planning'>planning guidance</a></td></tr>"
    Add-Html "<tr><td>7</td><td>Run a <b>test migration</b> on a non-production VM to validate the process and timings.</td><td>Recommended</td></tr>"
    Add-Html "</table>"

    # Paths overview
    Add-Html "<h2 id='paths'>4. Migration paths overview</h2>"
    Add-Html "<table><tr><th>Path</th><th>When it applies</th><th>Difficulty</th><th>Downtime</th><th>VMs</th></tr>"
    foreach ($key in $pathCatalog.Keys) {
        $p = $pathCatalog[$key]
        Add-Html "<tr><td><b>$(ConvertTo-HtmlText $p.Name)</b></td><td>$(ConvertTo-HtmlText $p.Description)</td><td>$(Get-PathBadge $p.Difficulty)</td><td>$(ConvertTo-HtmlText $p.Downtime)</td><td>$($pathCounts[$key])</td></tr>"
    }
    Add-Html "</table>"

    # Detailed steps per path
    Add-Html "<h2 id='steps'>5. Detailed steps per migration path</h2>"
    if ($usedPaths.Count -eq 0) {
        Add-Html "<p>No VMs in the analyzed scope need migration steps.</p>"
    }
    Add-Html "<p>Follow the steps for the path assigned to each VM. Replace values in angle brackets (for example <code>&lt;rg&gt;</code>) with the values for the VM. The VM list for each path is in <a href='#vms'>section 6</a>.</p>"
    foreach ($key in $usedPaths) {
        $p = $pathCatalog[$key]
        $names = @($results | Where-Object { $_.MigrationPath -eq $key } | ForEach-Object { $_.VmName })
        Add-Html "<h3 id='path-$key'>$(ConvertTo-HtmlText $p.Name) $(Get-PathBadge $p.Difficulty)</h3>"
        Add-Html "<p>$(ConvertTo-HtmlText $p.Description)</p>"
        Add-Html "<p><b>Applies to $($names.Count) VM(s):</b> $(ConvertTo-HtmlText ($names -join ', ')) &middot; <b>Downtime:</b> $(ConvertTo-HtmlText $p.Downtime)</p>"
        Add-Html "<ol class='steps'>"
        foreach ($step in $p.Steps) {
            $item = "<li><b>$(ConvertTo-HtmlText $step.Title)</b><br>$(ConvertTo-HtmlText $step.Text)"
            if ($step.Code) { $item += "<pre><code>$(ConvertTo-HtmlText $step.Code)</code></pre>" }
            Add-Html "$item</li>"
        }
        Add-Html "</ol>"
    }

    # Domain-joined VMs
    Add-Html "<h3 id='domain'>Domain-joined VMs</h3>"
    $domainVms = @($adeResults | Where-Object { $_.DomainJoined })
    Add-Html "<p>A new VM created from copied disks keeps the same computer name and domain secure channel in most cases. If the secure channel breaks (for example the old VM was running at the same time, or the machine account password changed), fix it as follows:</p>"
    Add-Html "<ol class='steps'>"
    Add-Html "<li><b>Before migration:</b> record the OU, security group memberships and any SPNs of the computer account.</li>"
    Add-Html "<li><b>Do not run the old and new VM at the same time</b> on the same network with the same computer name.</li>"
    $domainFixCode = (
        'Test-ComputerSecureChannel -Repair -Credential (Get-Credential)',
        '# or',
        'Remove-Computer -UnjoinDomainCredential (Get-Credential) -WorkgroupName TEMP -Restart',
        'Add-Computer -DomainName "<domain>" -OUPath "<OU>" -Credential (Get-Credential) -Restart'
    ) -join "`n"
    Add-Html ("<li><b>If trust fails:</b> repair the secure channel, or unjoin and rejoin the domain.<pre><code>{0}</code></pre></li>" -f (ConvertTo-HtmlText $domainFixCode))
    Add-Html "<li><b>After rejoin:</b> the computer account can get a new SID. Restore group memberships and update any permissions that reference the old account.</li>"
    Add-Html "</ol>"
    if ($domainVms.Count -gt 0) {
        Add-Html "<p><b>VMs that appear to be domain-joined:</b> $(ConvertTo-HtmlText (($domainVms | ForEach-Object { $_.VmName }) -join ', '))</p>"
    }
    else {
        Add-Html "<p>No domain-joined VMs were detected (detection is based on domain join extensions and tags; verify manually).</p>"
    }

    # VMs by path
    Add-Html "<h2 id='vms'>6. VMs by migration path</h2>"
    foreach ($key in $pathCatalog.Keys) {
        $rows = @($results | Where-Object { $_.MigrationPath -eq $key } | Sort-Object ResourceGroup, VmName)
        if ($rows.Count -eq 0) { continue }
        $p = $pathCatalog[$key]
        $stepLink = if ($usedPaths -contains $key) { " &middot; <a href='#path-$key'>see steps</a>" } else { '' }
        Add-Html "<h3 id='vms-$key'>$(ConvertTo-HtmlText $p.Name) ($($rows.Count)) $(Get-PathBadge $p.Difficulty)$stepLink</h3>"
        Add-Html "<table><tr><th>VM</th><th>Resource group</th><th>Location</th><th>OS</th><th>Size</th><th>Power</th><th>ADE</th><th>Encrypted</th><th>Disks / GiB</th><th>Copy (min)</th><th>Effort (h)</th><th>Size supports EAH</th><th>Domain</th><th>Backup</th><th>Key Vaults</th></tr>"
        foreach ($r in $rows) {
            $sizeCell = switch ($r.SizeSupportsEah) { $true { "<span class='ok'>Yes</span>" } $false { "<span class='bad'>No</span>" } default { 'Unknown' } }
            $backupCell = switch ($r.BackupProtected) { $true { "<span class='ok'>Yes</span>" } $false { "<span class='bad'>No</span>" } default { 'Not checked' } }
            $domainCell = if ($r.DomainJoined) { 'Yes' } else { 'No' }
            $adeCell = if ($r.AdeExtension) { "$(ConvertTo-HtmlText $r.AdeExtension) $(ConvertTo-HtmlText $r.AdeVersion)" } else { '&mdash;' }
            Add-Html ("<tr><td><b>{0}</b></td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}</td><td>{8} / {9}</td><td>{10}</td><td>{11}</td><td>{12}</td><td>{13}</td><td>{14}</td><td>{15}</td></tr>" -f `
                (ConvertTo-HtmlText $r.VmName), (ConvertTo-HtmlText $r.ResourceGroup), (ConvertTo-HtmlText $r.Location), (ConvertTo-HtmlText $r.OsType), (ConvertTo-HtmlText $r.VmSize), (ConvertTo-HtmlText $r.PowerState), $adeCell, (ConvertTo-HtmlText $r.EncryptedScope), $r.DiskCount, $r.TotalDiskGiB, $r.EstimatedCopyMinutes, $r.EffortHours, $sizeCell, $domainCell, $backupCell, (Get-HtmlList $r.KeyVaults))
        }
        Add-Html "</table>"
    }
    if ($results.Count -eq 0) { Add-Html "<p>No VMs were found in the analyzed scope.</p>" }

    # Issues
    Add-Html "<h2 id='issues'>7. Blockers and warnings</h2>"
    Add-Html "<p><b>Blockers</b> must be resolved before the VM can be migrated. <b>Warnings</b> need attention during planning but do not stop the migration.</p>"
    $issueRows = @($results | Where-Object { @($_.Blockers).Count -gt 0 -or @($_.Warnings).Count -gt 0 } | Sort-Object VmName)
    if ($issueRows.Count -eq 0) {
        Add-Html "<p class='ok'>No blockers or warnings were found.</p>"
    }
    else {
        Add-Html "<table><tr><th>VM</th><th>Resource group</th><th>Migration path</th><th>Blockers</th><th>Warnings</th></tr>"
        foreach ($r in $issueRows) {
            $blk = Get-HtmlList $r.Blockers
            if (@($r.Blockers).Count -gt 0) { $blk = "<span class='bad'>$blk</span>" }
            Add-Html "<tr><td>$(ConvertTo-HtmlText $r.VmName)</td><td>$(ConvertTo-HtmlText $r.ResourceGroup)</td><td>$(ConvertTo-HtmlText $pathCatalog[$r.MigrationPath].Name)</td><td>$blk</td><td>$(Get-HtmlList $r.Warnings)</td></tr>"
        }
        Add-Html "</table>"
    }
    if ($failures.Count -gt 0) {
        Add-Html "<h3>VMs that could not be analyzed</h3><table><tr><th>VM</th><th>Resource group</th><th>Error</th></tr>"
        foreach ($f in $failures) { Add-Html "<tr><td>$(ConvertTo-HtmlText $f.VmName)</td><td>$(ConvertTo-HtmlText $f.ResourceGroup)</td><td class='bad'>$(ConvertTo-HtmlText $f.Error)</td></tr>" }
        Add-Html "</table>"
    }


    # Cleanup
    Add-Html "<h2 id='cleanup'>8. Post-migration cleanup</h2>"
    Add-Html "<p>Do these steps only after each migrated VM has been verified (applications working, encryption at host shown as enabled, backups running).</p>"
    Add-Html "<ol class='steps'>"
    Add-Html "<li><b>Confirm encryption at host is active</b> on the new VM.<pre><code>(Get-AzVM -ResourceGroupName `"&lt;rg&gt;`" -Name `"&lt;vm&gt;`").SecurityProfile.EncryptionAtHost</code></pre></li>"
    Add-Html "<li><b>Configure backup for the new VM</b> and confirm the first backup succeeds. Keep the recovery points of the original VM until your retention requirements are met, then stop protection for the old VM.</li>"
    Add-Html "<li><b>Delete the original VM and its resources</b> (VM, OS and data disks, NICs, public IPs and snapshots created for the migration) once you no longer need a rollback option.<pre><code>Remove-AzVM -ResourceGroupName `"&lt;rg&gt;`" -Name `"&lt;old vm&gt;`"`nRemove-AzDisk -ResourceGroupName `"&lt;rg&gt;`" -DiskName `"&lt;old disk&gt;`"`nRemove-AzNetworkInterface -ResourceGroupName `"&lt;rg&gt;`" -Name `"&lt;old nic&gt;`"</code></pre></li>"
    Add-Html "<li><b>Review the Key Vaults used by ADE.</b> When no VM uses a vault for ADE any more, turn off the disk encryption access policy. Do not delete the keys or secrets until all backups that depend on them have expired.</li>"
    Add-Html "</ol>"
    if ($allKeyVaults.Count -gt 0) {
        Add-Html "<table><tr><th>Key Vault</th><th>VMs still referencing it</th><th>Command after all of them are migrated</th></tr>"
        foreach ($kv in $allKeyVaults) {
            $users = @($results | Where-Object { @($_.KeyVaults) -contains $kv } | ForEach-Object { $_.VmName } | Sort-Object)
            Add-Html "<tr><td>$(ConvertTo-HtmlText $kv)</td><td>$(Get-HtmlList $users)</td><td><code>Remove-AzKeyVaultAccessPolicy -VaultName `"$(ConvertTo-HtmlText $kv)`" -EnabledForDiskEncryption</code></td></tr>"
        }
        Add-Html "</table>"
    }
    else {
        Add-Html "<p>No Key Vaults used by ADE were found.</p>"
    }

    # Automation
    Add-Html "<h2 id='automation'>9. Optional automation</h2>"
    Add-Html "<p>The <code>Convert-AzVmAdeToEncryptionAtHost.ps1</code> script in the <code>azure-vm-lifecycle-tools</code> folder of the scripts repository can automate the copy-to-new-disks workflow for supported VMs. It runs in two stages:</p>"
    Add-Html "<ol class='steps'>"
    Add-Html "<li><b>Prepare</b> &mdash; checks the VM, disables ADE where the documentation allows it and confirms the volumes are decrypted.<pre><code>.\Convert-AzVmAdeToEncryptionAtHost.ps1 -SubscriptionId `"$(ConvertTo-HtmlText $SubscriptionId)`" -ResourceGroupName `"&lt;rg&gt;`" -VmName `"&lt;vm&gt;`" -Stage Prepare</code></pre></li>"
    Add-Html "<li><b>Migrate (preview first)</b> &mdash; run with <code>-WhatIf</code> to see every action without changing anything.<pre><code>.\Convert-AzVmAdeToEncryptionAtHost.ps1 -SubscriptionId `"$(ConvertTo-HtmlText $SubscriptionId)`" -ResourceGroupName `"&lt;rg&gt;`" -VmName `"&lt;vm&gt;`" -Stage Migrate -WhatIf</code></pre></li>"
    Add-Html "<li><b>Migrate</b> &mdash; creates new disks, copies the data and builds the new VM with encryption at host. Add <code>-AllowExtensionLoss</code> only if you accept that VM extensions must be reinstalled on the new VM.</li>"
    Add-Html "</ol>"
    Add-Html "<div class='warn'>The automation needs <b>AzCopy</b> on the machine that runs it and <b>Run Command</b> access to the VM. Always test it on the pilot VM first. Linux VMs with an encrypted OS disk, AVD session hosts and VMs on the manual path are not handled by the automation.</div>"


    # Planning
    $pathWaves = @{
        WindowsOsOnly = 2; WindowsOsData = 2; LinuxDataOnly = 2
        AvdSessionHost = 3; LinuxOsRebuild = 3; Manual = 4
    }
    $waveNames = @{
        1 = 'Wave 1 - Pilot'
        2 = 'Wave 2 - Standard migrations (low/medium effort)'
        3 = 'Wave 3 - Rebuilds and session hosts (high effort)'
        4 = 'Wave 4 - Resolve blockers, then migrate'
    }
    $pilot = $adeResults | Where-Object { $_.MigrationPath -in @('WindowsOsOnly', 'WindowsOsData', 'LinuxDataOnly') -and @($_.Blockers).Count -eq 0 } |
        Sort-Object -Property EffortHours | Select-Object -First 1
    $waveRows = foreach ($r in $adeResults) {
        $wave = if ($pilot -and $r.VmName -eq $pilot.VmName -and $r.ResourceGroup -eq $pilot.ResourceGroup) { 1 }
        elseif (@($r.Blockers).Count -gt 0) { 4 }
        elseif ($pathWaves.ContainsKey($r.MigrationPath)) { $pathWaves[$r.MigrationPath] }
        else { 4 }
        [pscustomobject]@{ Wave = $wave; Result = $r }
    }

    Add-Html "<h2 id='planning'>10. Planning and effort estimate</h2>"
    Add-Html "<div class='cards'>"
    Add-Html "<div class='card'><div class='num'>$($adeResults.Count)</div><div class='lbl'>VMs to migrate</div></div>"
    Add-Html "<div class='card'><div class='num'>$totalGiB</div><div class='lbl'>GiB of disk to copy</div></div>"
    Add-Html "<div class='card'><div class='num'>$([math]::Round($totalCopyMinutes / 60, 1))</div><div class='lbl'>Hours of data copy (est.)</div></div>"
    Add-Html "<div class='card'><div class='num'>$totalEffort</div><div class='lbl'>Total effort hours (est.)</div></div>"
    Add-Html "</div>"
    Add-Html "<div class='warn'><b>Deadline:</b> Azure Disk Encryption retires on <b>September 15, 2028</b>. Plan your waves so that all VMs are migrated well before that date and leave time for testing and rollback.</div>"

    if ($adeResults.Count -gt 0) {
        Add-Html "<h3>Suggested migration waves</h3>"
        Add-Html "<p>Start with one low-risk pilot VM to validate the process, your change windows and your backup/restore procedures. Then migrate in waves of increasing complexity.</p>"
        foreach ($w in 1..4) {
            $rows = @($waveRows | Where-Object { $_.Wave -eq $w })
            if ($rows.Count -eq 0) { continue }
            $waveHours = [math]::Round((($rows | ForEach-Object { $_.Result.EffortHours } | Measure-Object -Sum).Sum + 0), 1)
            Add-Html "<h4>$(ConvertTo-HtmlText $waveNames[$w]) &mdash; $($rows.Count) VM(s), about $waveHours hour(s)</h4>"
            Add-Html "<table><tr><th>VM</th><th>Resource group</th><th>Path</th><th>Difficulty</th><th>Disk GiB</th><th>Copy (min)</th><th>Effort (h)</th></tr>"
            foreach ($row in ($rows | Sort-Object -Property { $_.Result.EffortHours })) {
                $r = $row.Result
                $p = $pathCatalog[$r.MigrationPath]
                Add-Html ("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td></tr>" -f (ConvertTo-HtmlText $r.VmName), (ConvertTo-HtmlText $r.ResourceGroup), (ConvertTo-HtmlText $p.Name), (Get-PathBadge $p.Difficulty), $r.TotalDiskGiB, $r.EstimatedCopyMinutes, $r.EffortHours)
            }
            Add-Html "</table>"
        }
    }

    Add-Html "<h3>Estimate assumptions</h3>"
    Add-Html "<ul>"
    Add-Html "<li>Data copy speed: <b>$CopyThroughputMBps MB/s</b> per disk (change with <code>-CopyThroughputMBps</code>). Copy time uses the provisioned disk size, so real times are often shorter.</li>"
    Add-Html "<li>Fixed overhead per VM (preparation, downtime window, verification): Windows OS only 2 h, Windows OS+data 3 h, Linux data only 3 h, AVD session host 4 h, Manual review 4 h, Linux OS rebuild 8 h.</li>"
    Add-Html "<li>Estimates are for one engineer working on one VM. VMs in the same wave can usually be migrated in parallel.</li>"
    Add-Html "<li>Add time for change approvals, application testing and any domain re-join or reconfiguration.</li>"
    Add-Html "</ul>"

    # Appendix
    $duration = (Get-Date).ToUniversalTime() - $startTime
    $rgText = if ($ResourceGroupName) { ($ResourceGroupName -join ', ') } else { 'All resource groups' }
    $backupText = if ($SkipBackupCheck) { 'Skipped (-SkipBackupCheck)' } elseif ($backupProviderMissing) { 'Microsoft.RecoveryServices provider not registered in the subscription, so no VM can be protected by Azure Backup' } elseif ($backupAvailable) { 'Checked with Az.RecoveryServices' } else { 'Not checked (Az.RecoveryServices module not available)' }
    Add-Html "<h2 id='appendix'>11. Appendix</h2>"
    Add-Html "<h3>Analysis settings</h3>"
    Add-Html "<table><tr><th>Setting</th><th>Value</th></tr>"
    Add-Html "<tr><td>Subscription</td><td>$(ConvertTo-HtmlText $subscriptionName) ($SubscriptionId)</td></tr>"
    Add-Html "<tr><td>Resource group filter</td><td>$(ConvertTo-HtmlText $rgText)</td></tr>"
    Add-Html "<tr><td>Include VMs without ADE</td><td>$([bool]$IncludeNonAdeVms)</td></tr>"
    Add-Html "<tr><td>Backup protection check</td><td>$(ConvertTo-HtmlText $backupText)</td></tr>"
    Add-Html "<tr><td>EncryptionAtHost feature registration</td><td>$(ConvertTo-HtmlText $featureState)</td></tr>"
    Add-Html "<tr><td>Copy throughput assumption</td><td>$CopyThroughputMBps MB/s</td></tr>"
    Add-Html "<tr><td>Parallel workers</td><td>$ThrottleLimit</td></tr>"
    Add-Html "<tr><td>VMs scanned</td><td>$(@($vms).Count)</td></tr>"
    Add-Html "<tr><td>VMs that could not be analyzed</td><td>$($failures.Count)$(if ($failures.Count -gt 0) { " (see <a href='#issues'>Blockers and warnings</a>)" })</td></tr>"
    Add-Html "<tr><td>Analysis duration</td><td>$([math]::Round($duration.TotalSeconds, 1)) seconds</td></tr>"
    Add-Html "</table>"
    Add-Html "<h3>References</h3><ul>"
    Add-Html "<li><a href='https://learn.microsoft.com/azure/virtual-machines/disk-encryption-migrate'>Migrate from Azure Disk Encryption to encryption at host</a></li>"
    Add-Html "<li><a href='https://learn.microsoft.com/azure/virtual-machines/disk-encryption'>Server-side encryption of Azure managed disks (encryption at host)</a></li>"
    Add-Html "<li><a href='https://learn.microsoft.com/azure/virtual-machines/disks-enable-host-based-encryption-portal'>Enable end-to-end encryption using encryption at host</a></li>"
    Add-Html "</ul>"
    Add-Html "<div class='footer'>Generated by Get-AzAdeMigrationPlan.ps1 on $($startTime.ToString('yyyy-MM-dd HH:mm')) UTC. This report is read-only analysis; no Azure resources were changed. Always validate the plan against the current Microsoft Learn documentation before migrating.</div>"
    Add-Html "</main></body></html>"

    Set-Content -Path $reportFile -Value $sb.ToString() -Encoding UTF8

    if ($csvFile) {
        $results | ForEach-Object {
            [PSCustomObject]@{
                VmName               = $_.VmName
                ResourceGroup        = $_.ResourceGroup
                Location             = $_.Location
                OsType               = $_.OsType
                VmSize               = $_.VmSize
                PowerState           = $_.PowerState
                AdeExtension         = $_.AdeExtension
                AdeVersion           = $_.AdeVersion
                EncryptedScope       = $_.EncryptedScope
                MigrationPath        = $_.MigrationPath
                MigrationPathName    = $pathCatalog[$_.MigrationPath].Name
                Supported            = $_.Supported
                SizeSupportsEah      = $_.SizeSupportsEah
                DomainJoined         = $_.DomainJoined
                AvdSessionHost       = $_.AvdSessionHost
                BackupProtected      = $_.BackupProtected
                DiskCount            = $_.DiskCount
                TotalDiskGiB         = $_.TotalDiskGiB
                EstimatedCopyMinutes = $_.EstimatedCopyMinutes
                EffortHours          = $_.EffortHours
                KeyVaults            = (@($_.KeyVaults) -join '; ')
                Blockers             = (@($_.Blockers) -join '; ')
                Warnings             = (@($_.Warnings) -join '; ')
                AnalyzedUtc          = $_.AnalyzedUtc
            }
        } | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    }

Write-Host ("ADE migration plan report: {0}" -f $reportFile) -ForegroundColor Green
if ($csvFile) { Write-Host ("CSV export: {0}" -f $csvFile) -ForegroundColor Green }

if ($PassThru) { $results }
}
catch {
    throw "ADE migration analysis failed: $($_.Exception.Message)"
}
