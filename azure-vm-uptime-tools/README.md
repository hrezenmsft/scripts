# Azure VM Uptime Tools

## Disclaimer

The sample scripts are not supported under any Microsoft standard support program or service. The sample scripts are provided AS IS without warranty of any kind. Microsoft further disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose. The entire risk arising out of the use or performance of the scripts and documentation remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the scripts be liable for any damages whatsoever arising out of the use of or inability to use the scripts or documentation.

PowerShell tools for estimating Azure VM uptime from successful start and deallocate Activity Log events, VM creation time, and current power state. All report timestamps are UTC.

## Choose a tool

| Script | Scope | Output | Default period |
| --- | --- | --- | --- |
| `Get-AzVmUptimeSingle.ps1` | One VM | Running-period table and total uptime | 30 days |
| `Get-AzVmUptimeSummary.ps1` | One resource group or the full subscription | Running-period table, per-VM totals, and combined uptime | 30 days |
| `Export-AzVmUptimePeriods.ps1` | Full subscription | UTF-8 CSV with one row per running period | 30 days |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- Azure CLI 2.x.
- Az PowerShell modules: `Az.Accounts` and `Az.Compute`.
- Permission to read VMs and subscription Activity Log events.
- For `-IncludeGuestUptime`, permission for `Microsoft.Compute/virtualMachines/runCommand/action` and a running Linux VM with the Azure VM agent.

The built-in Azure `Reader` role normally provides the required permissions. A custom role must allow `Microsoft.Compute/virtualMachines/read` and `Microsoft.Insights/eventtypes/values/read`.

## Installation

```powershell
Install-Module Az.Accounts, Az.Compute -Scope CurrentUser
git clone https://github.com/hrezenmsft/scripts.git
Set-Location .\scripts\azure-vm-uptime-tools
```

Install Azure CLI using the [official installation instructions](https://learn.microsoft.com/cli/azure/install-azure-cli). Sign in and select the subscription to report on:

```powershell
az login
az account set --subscription "<subscription-name-or-id>"
```

Each script verifies the Azure CLI session and uses its access token to connect Az PowerShell to the same account, tenant, and subscription. If the session is missing or expired, the script stops and instructs you to run `az login`; it never starts authentication automatically.

## Single VM report

```powershell
.\Get-AzVmUptimeSingle.ps1 -VMName "example-vm" -ResourceGroupName "example-rg" -DaysAgo 30
```

`-VM` and `-RG` are aliases. If either name is omitted, the script prompts for it. `-DaysAgo` accepts 1 through 90.

```powershell
Get-Help .\Get-AzVmUptimeSingle.ps1 -Full
```

## Summary report

Run against every VM in the active subscription:

```powershell
.\Get-AzVmUptimeSummary.ps1
```

When no resource group is supplied, the script displays a numbered menu where
you can select one resource group or all resource groups.

Limit the report to a resource group:

```powershell
.\Get-AzVmUptimeSummary.ps1 -ResourceGroupName "example-rg" -DaysAgo 7
```

`-RG` is an alias for `-ResourceGroupName`. Supplying the parameter skips the
interactive menu. `-DaysAgo` accepts 1 through 90; the summary default is 90.

To add actual Linux guest uptime, retrieved with the read-only `cut -d. -f1 /proc/uptime`
command through Azure Run Command:

```powershell
.\Get-AzVmUptimeSummary.ps1 -ResourceGroupName "example-rg" -IncludeGuestUptime
```

`TotalUptime` remains the management-plane running time within the selected
window. `GuestUptime` reports the OS boot-based uptime for supported running
Linux VMs. It is unavailable for stopped VMs, Windows VMs, or VMs where Run
Command cannot execute.

```powershell
Get-Help .\Get-AzVmUptimeSummary.ps1 -Full
```

## CSV export

Export the previous 30 days to a timestamped CSV in the current directory:

```powershell
.\Export-AzVmUptimePeriods.ps1
```

Choose the period and destination:

```powershell
.\Export-AzVmUptimePeriods.ps1 -DaysAgo 7 -OutputPath .\vm-uptime-periods.csv
```

The CSV includes subscription, resource group, VM name, current power state, query boundaries, period boundaries, decimal duration values, and whether the period remained open at the query cutoff.

```powershell
Get-Help .\Export-AzVmUptimePeriods.ps1 -Full
```

## Calculation notes

- Only successful start and deallocate operations are counted.
- VM creation within the reporting window is treated as an initial start.
- A running VM with no matching events is treated as running for the full window.
- `-IncludeGuestUptime` reads Linux `/proc/uptime` through Azure Run Command and can report the actual guest OS uptime.
- The CSV exporter treats a first deallocate event as evidence that the VM was running when the window opened.
- Restarts without deallocation are treated as continuous runtime.
- Guest-initiated shutdowns might not create a matching deallocate event.
- Azure Activity Log queries cannot start more than 90 days in the past. For a year-long report, export Activity Logs to Log Analytics or a storage account before the 90-day retention window expires.
- Large subscriptions may take time because Activity Log data is queried for each VM.

These reports use management-plane events and are not SLA, billing, or guest operating system availability reports.

## Troubleshooting

Confirm the active subscription and authentication state:

```powershell
az login
az account set --subscription "<subscription-name-or-id>"
az account show --output table
```

Run `az login` yourself only when the session is missing or expired; the reporting scripts never launch authentication.

Confirm that a VM can be read:

```powershell
az vm show --name "<vm-name>" --resource-group "<resource-group-name>" --output table
```

## Security

- The scripts do not request or store passwords.
- Azure CLI handles authentication and persistent token caching.
- An access token is held only in process memory while establishing the Az PowerShell context.
- Avoid verbose or transcript logging when debugging token-bearing commands.

## Author

Henrique Rezende

## License

Licensed under the [MIT License](LICENSE).