# Windows Network Diagnostic Tools

## Disclaimer

The sample scripts are not supported under any Microsoft standard support program or service. They are provided AS IS without warranty of any kind. The entire risk arising from their use or performance remains with you.

PowerShell tools for Windows RDP diagnostics, Active Directory TCP reachability testing, and ongoing TCP/UDP endpoint monitoring.

## Choose a tool

| Script | Purpose |
| --- | --- |
| `Test-WindowsRdpReadiness.ps1` | Diagnose common guest-side reasons a Windows machine cannot accept RDP connections. |
| `Test-AdDomainConnectivity.ps1` | Discover a domain controller and test common AD DS TCP ports. |
| `Start-WindowsNetworkEndpointMonitor.ps1` | Sample grouped TCP connections and UDP endpoints into CSV logs. |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows.
- Permission to inspect network and process information.
- Administrator privileges are recommended for complete registry, firewall, certificate, event log, and process information.

```powershell
git clone https://github.com/hrezenmsft/Scripts.git
Set-Location .\Scripts\windows-network-diagnostic-tools
```

## Diagnose Windows RDP readiness

`Test-WindowsRdpReadiness.ps1` is a compact, self-contained diagnostic intended for local execution on an affected machine through Azure Run Command, Serial Console, Hyper-V console, or another recovery channel. It can also inspect a mounted Windows installation from a rescue VM.

The final report displays every check and highlights recommended actions for failures and warnings. Checks cover:

- Local and policy-based RDP enablement.
- RDP listener settings, configured port, and process ownership.
- Critical Windows and RDP services, TermService registration, and `termsrv.dll`.
- Domain secure channel on domain-joined machines.
- RDP listener certificate presence, validity, and private key.
- Guest IPv4 and default-route configuration.
- Effective Windows Firewall allow and block rules for the RDP port.
- Recent TermService, RDP rejection, certificate, and failed-logon events.

Run from an elevated PowerShell session on the affected machine:

```powershell
.\Test-WindowsRdpReadiness.ps1
```

Return all checks as structured objects:

```powershell
.\Test-WindowsRdpReadiness.ps1 -Detailed
```

Export all results to CSV:

```powershell
.\Test-WindowsRdpReadiness.ps1 `
    -EventLookbackHours 48 `
    -FailedLogonWarningThreshold 100 `
    -OutputPath .\rdp-readiness.csv
```

From an elevated PowerShell session on a rescue VM, inspect a mounted OS disk:

```powershell
.\Test-WindowsRdpReadiness.ps1 `
    -OfflineWindowsPath F:\Windows `
    -OutputPath .\rdp-offline-readiness.csv
```

Offline mode inspects persistent RDP configuration, disabled dependencies, TermService registration, binaries, and available event logs. Runtime listener, active firewall, NIC, domain trust, and certificate private-key state must be rechecked after the affected OS boots.

A result of `NO GUEST BLOCKER FOUND` does not prove end-to-end reachability. Validate Azure NSGs, effective routes, load balancer or NAT rules, public IP mappings, Bastion or JIT state, VPN paths, upstream firewalls, and Microsoft Defender for Endpoint isolation separately.

```powershell
Get-Help .\Test-WindowsRdpReadiness.ps1 -Full
```

## Test AD domain connectivity

The script uses `nltest.exe` to discover a domain controller unless `-DomainController` is supplied. It tests TCP ports 53, 88, 135, 389, 445, 636, 3268, and 3269.

After returning the detailed result objects, the script displays a summary with the tested domain controller, reachable and unreachable counts, success rate, and a per-service table showing each TCP port and its connectivity status. When CSV export is enabled, the summary also shows the resolved output path.

```powershell
.\Test-AdDomainConnectivity.ps1 -DomainName contoso.com | Format-Table -AutoSize
```

Specify a domain controller and export results:

```powershell
.\Test-AdDomainConnectivity.ps1 `
    -DomainName contoso.com `
    -DomainController dc01.contoso.com `
    -OutputPath .\ad-connectivity.csv
```

A successful result confirms TCP reachability only. It does not validate authentication, DNS record correctness, replication, LDAP bind operations, or application-level health. Dynamic RPC uses a port range and is not represented by testing one arbitrary high port.

```powershell
Get-Help .\Test-AdDomainConnectivity.ps1 -Full
```

## Monitor TCP and UDP endpoints

Run continuously with a 10-second interval:

```powershell
.\Start-WindowsNetworkEndpointMonitor.ps1
```

When `-OutputDirectory` is omitted, each run creates a unique directory under the current user's temporary folder. The script prints the resolved directory and full TCP and UDP CSV paths before monitoring starts and again when monitoring ends.

Collect 10 samples at 30-second intervals:

```powershell
.\Start-WindowsNetworkEndpointMonitor.ps1 `
    -IntervalSeconds 30 `
    -SampleCount 10 `
    -Top 50 `
    -OutputDirectory "$env:TEMP\NetworkEndpoints"
```

The output directory is created automatically. Results are appended to:

- `tcp-connection-groups.csv`
- `udp-endpoint-groups.csv`

Each row includes the UTC sample timestamp, sample number, protocol, grouped endpoint count, state, owning process ID, process name, and command line. UDP has no connection state, so its rows use `Endpoint`.

`-SampleCount 0` runs until interrupted with `Ctrl+C`. CSV files grow continuously and are not rotated.

```powershell
Get-Help .\Start-WindowsNetworkEndpointMonitor.ps1 -Full
```

## Security and privacy

- Process command lines can contain secrets or sensitive arguments.
- RDP results can expose computer names, IP addresses, certificate thumbprints, service state, and security configuration.
- Protect, retain, and delete generated CSV files according to your organization's policy.
- Endpoint and process enumeration can be incomplete without administrator access.
- Short intervals increase collection overhead and log growth.

## Author

Henrique Rezende

## License

Licensed under the [MIT License](LICENSE).