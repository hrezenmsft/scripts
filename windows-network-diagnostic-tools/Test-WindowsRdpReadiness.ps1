<#
.SYNOPSIS
Diagnoses common guest-side causes of RDP failure on a Windows VM.

.DESCRIPTION
Runs locally through Run Command, Serial Console, or another console method.
OfflineWindowsPath inspects a mounted Windows installation from a rescue VM.
The final report displays all checks. Use Detailed to also return structured
result objects to the pipeline, or OutputPath to export them to CSV.

.PARAMETER OutputPath
Optional CSV destination for all results.

.PARAMETER OfflineWindowsPath
Mounted Windows directory of the affected VM, for example F:\Windows.

.PARAMETER EventLookbackHours
Hours of recent RDP-related events to inspect. The default is 24.

.PARAMETER FailedLogonWarningThreshold
Failed RDP logons that trigger a warning. The default is 100.

.PARAMETER Detailed
Returns all result objects to the pipeline.

.EXAMPLE
.\Test-WindowsRdpReadiness.ps1

.EXAMPLE
.\Test-WindowsRdpReadiness.ps1 -Detailed

.EXAMPLE
.\Test-WindowsRdpReadiness.ps1 -OfflineWindowsPath F:\Windows

.NOTES
Author: Henrique Rezende
Version: 1.0.0
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$OfflineWindowsPath,
    [ValidateRange(1, 168)][int]$EventLookbackHours = 24,
    [ValidateRange(1, 100000)][int]$FailedLogonWarningThreshold = 100,
    [switch]$Detailed
)

if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) {
    throw "This script can run only on Windows."
}

$script:Results = [System.Collections.Generic.List[object]]::new()
$script:ComputerName = $env:COMPUTERNAME
$script:RdpPort = 3389
$script:SecurityLayer = $null

function Add-Result {
    param(
        [string]$Check,
        [ValidateSet("Pass", "Fail", "Warning", "Information")][string]$Status,
        [string]$Details,
        [string]$Recommendation = "None."
    )

    $script:Results.Add([PSCustomObject]@{
        ComputerName = $script:ComputerName
        Check = $Check
        Status = $Status
        Details = $Details
        Recommendation = $Recommendation
    })
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RegValue {
    param([string]$Path, [string]$Name)

    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        try {
            if ($key.GetValueNames() -contains $Name) {
                return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
        finally {
            $key.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Resolve-WindowsPath {
    param([string]$Value, [string]$WindowsPath)

    $path = $Value -replace "(?i)%SystemRoot%|%windir%|^\\SystemRoot", $WindowsPath
    $pathMatch = [regex]::Match($path, "^[A-Za-z]:\\Windows\\(.+)$", "IgnoreCase")
    if ($pathMatch.Success -and $WindowsPath -notmatch "^[A-Za-z]:\\Windows$") {
        $path = Join-Path $WindowsPath $pathMatch.Groups[1].Value
    }
    $path
}

function Test-RdpConfiguration {
    param([string]$TerminalServerPath, [string]$RdpTcpPath, [string]$PolicyPath)

    if (-not (Test-Path -LiteralPath $RdpTcpPath)) {
        Add-Result "RDP listener configuration" "Fail" "The RDP-Tcp registry key is missing." "Restore the listener from the same Windows version or repair Windows."
        return
    }

    $localDeny = Get-RegValue $TerminalServerPath "fDenyTSConnections"
    $policyDeny = Get-RegValue $PolicyPath "fDenyTSConnections"
    if ($policyDeny -eq 1) {
        Add-Result "Remote Desktop enabled" "Fail" "Policy disables RDP." "Change the controlling Group Policy or MDM policy."
    }
    elseif ($localDeny -ne 0) {
        Add-Result "Remote Desktop enabled" "Fail" "Local configuration disables RDP (fDenyTSConnections=$localDeny)." "Set fDenyTSConnections to 0 after confirming policy."
    }
    else {
        Add-Result "Remote Desktop enabled" "Pass" "Incoming RDP connections are enabled."
    }

    $port = Get-RegValue $RdpTcpPath "PortNumber"
    if ($port -and [int64]$port -ge 1 -and [int64]$port -le 65535) {
        $script:RdpPort = [int]$port
        Add-Result "RDP port" "Pass" "Configured port: TCP/$script:RdpPort."
    }
    else {
        Add-Result "RDP port" "Fail" "No valid PortNumber is configured." "Set a valid listener port, normally 3389."
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $enableWinStation = Get-RegValue $RdpTcpPath "fEnableWinStation"
    $logonDisabled = Get-RegValue $RdpTcpPath "fLogonDisabled"
    $drainMode = Get-RegValue $TerminalServerPath "TSServerDrainMode"
    $lanAdapter = Get-RegValue $RdpTcpPath "LanAdapter"
    $maxInstances = Get-RegValue $RdpTcpPath "MaxInstanceCount"
    $script:SecurityLayer = Get-RegValue $RdpTcpPath "SecurityLayer"
    $nla = Get-RegValue $RdpTcpPath "UserAuthentication"

    if ($enableWinStation -ne 1) { $problems.Add("fEnableWinStation=$enableWinStation") }
    if ($logonDisabled -and [int]$logonDisabled -ne 0) { $problems.Add("fLogonDisabled=$logonDisabled") }
    if ($drainMode -and [int]$drainMode -ne 0) { $problems.Add("TSServerDrainMode=$drainMode") }
    if ($maxInstances -eq 0) { $problems.Add("MaxInstanceCount=0") }
    if ($lanAdapter -and [int]$lanAdapter -ne 0) { $warnings.Add("bound to adapter $lanAdapter") }
    if ($script:SecurityLayer -notin @(0, 1, 2)) { $problems.Add("SecurityLayer=$script:SecurityLayer") }
    if ($nla -eq 0) { $warnings.Add("NLA disabled") }

    if ($problems.Count) {
        Add-Result "RDP listener settings" "Fail" ($problems -join "; ") "Restore valid RDP-Tcp listener settings."
    }
    elseif ($warnings.Count) {
        Add-Result "RDP listener settings" "Warning" ($warnings -join "; ") "Confirm these settings are intentional."
    }
    else {
        Add-Result "RDP listener settings" "Pass" "Listener, logon, binding, security, and connection-limit settings are valid."
    }
}

function Test-TermServiceConfiguration {
    param([string]$ServicePath, [string]$WindowsPath)

    $start = Get-RegValue $ServicePath "Start"
    $account = Get-RegValue $ServicePath "ObjectName"
    $imagePath = Get-RegValue $ServicePath "ImagePath"
    $serviceDll = Get-RegValue (Join-Path $ServicePath "Parameters") "ServiceDll"
    $problems = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $start -or [int]$start -eq 4) { $problems.Add("service disabled or Start missing") }
    if ($account -notmatch "(?i)NetworkService$") { $problems.Add("account=$account") }
    if ($imagePath -notmatch "(?i)\\System32\\svchost\.exe.*-k\s+(termsvcs|NetworkService)") { $problems.Add("unexpected ImagePath") }
    if (-not $serviceDll) {
        $problems.Add("ServiceDll missing")
    }
    else {
        $resolvedDll = Resolve-WindowsPath ([string]$serviceDll) $WindowsPath
        if ($resolvedDll -notmatch "(?i)\\System32\\termsrv\.dll$" -or -not (Test-Path -LiteralPath $resolvedDll)) {
            $problems.Add("termsrv.dll missing or unexpected")
        }
    }

    if ($problems.Count) {
        Add-Result "TermService registration" "Fail" ($problems -join "; ") "Repair the service registration and Windows component files."
    }
    else {
        Add-Result "TermService registration" "Pass" "Startup, account, image path, and termsrv.dll are valid."
    }
}

function Test-OnlineServices {
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $services = @{}
    Get-CimInstance Win32_Service -ErrorAction Stop | ForEach-Object { $services[$_.Name] = $_ }
    $required = @("Dnscache", "LSM", "ProfSvc", "LanmanWorkstation", "TermService", "RpcSs", "BFE", "MpsSvc")
    if ($computer.PartOfDomain) { $required += "Netlogon" }
    $onDemand = @("SessionEnv", "UmRdpService")
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $required) {
        $service = $services[$name]
        if (-not $service) { $problems.Add("$name missing") }
        elseif ($service.StartMode -eq "Disabled") { $problems.Add("$name disabled") }
        elseif ($service.State -ne "Running") { $problems.Add("$name $($service.State), exit $($service.ExitCode)") }
    }
    foreach ($name in $onDemand) {
        $service = $services[$name]
        if (-not $service) { $problems.Add("$name missing") }
        elseif ($service.StartMode -eq "Disabled") { $problems.Add("$name disabled") }
    }

    if ($problems.Count) {
        Add-Result "Critical services" "Fail" ($problems -join "; ") "Restore default startup modes and investigate service failures."
    }
    else {
        Add-Result "Critical services" "Pass" "Required services are running; RDP helper services are available."
    }

    if (-not $computer.PartOfDomain) {
        Add-Result "Domain secure channel" "Information" "Workgroup computer; secure channel does not apply."
    }
    else {
        try {
            if (Test-ComputerSecureChannel -ErrorAction Stop) {
                Add-Result "Domain secure channel" "Pass" "Trust with $($computer.Domain) is healthy."
            }
            else {
                Add-Result "Domain secure channel" "Fail" "Trust with $($computer.Domain) is broken." "Repair the computer secure channel."
            }
        }
        catch {
            Add-Result "Domain secure channel" "Warning" $_.Exception.Message "Verify DNS, DC connectivity, and the computer account."
        }
    }

    $services["TermService"]
}

function Test-OnlineCertificate {
    param([string]$RdpTcpPath)

    try {
        $setting = Get-CimInstance -Namespace "root\cimv2\TerminalServices" -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-tcp'" -ErrorAction Stop
        $thumbprint = ([string]$setting.SSLCertificateSHA1Hash -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
        if (-not $thumbprint) { throw "No listener certificate thumbprint is configured." }
        $certificate = Get-ChildItem Cert:\LocalMachine\My, "Cert:\LocalMachine\Remote Desktop" -ErrorAction SilentlyContinue |
            Where-Object Thumbprint -eq $thumbprint | Select-Object -First 1
        if (-not $certificate) { throw "Certificate $thumbprint is missing." }
        if ($certificate.NotBefore -gt (Get-Date) -or $certificate.NotAfter -lt (Get-Date)) { throw "Certificate $thumbprint is expired or not yet valid." }
        if (-not $certificate.HasPrivateKey) { throw "Certificate $thumbprint has no accessible private key." }
        Add-Result "RDP certificate" "Pass" "Certificate $thumbprint is present, valid, and has a private key."
    }
    catch {
        $status = if ($script:SecurityLayer -eq 2) { "Fail" } else { "Warning" }
        Add-Result "RDP certificate" $status $_.Exception.Message "Repair the binding or allow Windows to recreate the listener certificate."
    }
}

function Test-OnlineNetwork {
    param($TermService)

    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" })
    $routes = @(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue)
    if (-not $addresses.Count -or -not $routes.Count) {
        Add-Result "Guest network" "Fail" "Usable IPv4 address or default route is missing." "Repair the NIC, DHCP/static IP, and gateway configuration."
    }
    else {
        Add-Result "Guest network" "Pass" "IPv4: $(($addresses.IPAddress | Sort-Object -Unique) -join ', '); gateway: $(($routes.NextHop | Sort-Object -Unique) -join ', ')."
    }

    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $script:RdpPort -ErrorAction SilentlyContinue)
    if (-not $listeners.Count) {
        Add-Result "RDP TCP listener" "Fail" "Nothing is listening on TCP/$script:RdpPort." "Check TermService and the RDP-Tcp configuration."
    }
    elseif ($TermService -and $TermService.ProcessId -and $listeners.OwningProcess -notcontains [int]$TermService.ProcessId) {
        Add-Result "RDP TCP listener" "Fail" "TCP/$script:RdpPort is owned by another process." "Identify the conflicting process."
    }
    else {
        Add-Result "RDP TCP listener" "Pass" "TCP/$script:RdpPort is listening."
    }
}

function Test-OnlineFirewall {
    try {
        $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop |
            Where-Object { $_.Enabled -eq "True" -and $_.Direction -eq "Inbound" })
        $allow = [System.Collections.Generic.List[string]]::new()
        $block = [System.Collections.Generic.List[string]]::new()
        foreach ($rule in $rules) {
            $rdpPortFilters = @(
                $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.Protocol -in @("TCP", 6) -and
                        ($_.LocalPort -eq $script:RdpPort -or ($_.LocalPort -eq "Any" -and $rule.Name -like "RemoteDesktop*"))
                    }
            )
            if ($rdpPortFilters.Count -gt 0) {
                if ($rule.Action -eq "Allow") { $allow.Add($rule.Name) }
                elseif ($rule.Action -eq "Block") { $block.Add($rule.Name) }
            }
        }
        if (-not $allow.Count) {
            Add-Result "Windows Firewall" "Fail" "No enabled inbound allow rule covers TCP/$script:RdpPort." "Enable or create an RDP allow rule for the active profile."
        }
        elseif ($block.Count) {
            Add-Result "Windows Firewall" "Warning" "Allow rule exists, but block rule(s) also match: $($block -join ', ')." "Review block-rule scope; block rules take precedence."
        }
        else {
            Add-Result "Windows Firewall" "Pass" "An enabled inbound allow rule covers TCP/$script:RdpPort."
        }
    }
    catch {
        Add-Result "Windows Firewall" "Warning" $_.Exception.Message "Run elevated and inspect effective firewall policy."
    }
}

function Get-Events {
    param([string]$LogName, [string]$Path, [int[]]$Id, [datetime]$StartTime)

    try {
        if ($Path) {
            if (-not (Test-Path -LiteralPath $Path)) { return @() }
            return @(Get-WinEvent -Path $Path -MaxEvents 1000 -ErrorAction Stop |
                Where-Object { $_.TimeCreated -ge $StartTime -and $_.Id -in $Id })
        }
        return @(Get-WinEvent -FilterHashtable @{ LogName = $LogName; Id = $Id; StartTime = $StartTime } -MaxEvents 1000 -ErrorAction Stop)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like "NoMatchingEventsFound*") { return @() }
        throw
    }
}

function Test-RecentEvents {
    param([string]$EventDirectory)

    $start = (Get-Date).AddHours(-$EventLookbackHours)
    $systemPath = if ($EventDirectory) { Join-Path $EventDirectory "System.evtx" } else { $null }
    $securityPath = if ($EventDirectory) { Join-Path $EventDirectory "Security.evtx" } else { $null }
    $rdpCorePath = if ($EventDirectory) { Join-Path $EventDirectory "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS%4Operational.evtx" } else { $null }
    $rcmPath = if ($EventDirectory) { Join-Path $EventDirectory "Microsoft-Windows-TerminalServices-RemoteConnectionManager%4Operational.evtx" } else { $null }

    try {
        $serviceEvents = @(Get-Events "System" $systemPath @(7000, 7001, 7009, 7011, 7022, 7023, 7024, 7031, 7034) $start |
            Where-Object { $_.ToXml() -match "(?i)TermService|Remote Desktop Services" })
        $rdpRejected = @(Get-Events "Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational" $rdpCorePath @(140) $start)
        $certEvents = @(Get-Events "Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational" $rcmPath @(1057, 1058) $start)
        $failedLogons = @(Get-Events "Security" $securityPath @(4625) $start |
            Where-Object { $_.ToXml() -match "<Data Name='LogonType'>(3|10|12)</Data>" })
        $details = "TermService=$($serviceEvents.Count); rejected=$($rdpRejected.Count); certificate=$($certEvents.Count); failedLogons=$($failedLogons.Count)"
        if ($serviceEvents.Count -or $certEvents.Count -or $failedLogons.Count -ge $FailedLogonWarningThreshold) {
            Add-Result "Recent RDP events" "Warning" $details "Review the listed event logs and restrict exposed RDP sources if failures are excessive."
        }
        else {
            Add-Result "Recent RDP events" "Pass" $details
        }
    }
    catch {
        Add-Result "Recent RDP events" "Information" $_.Exception.Message "Review System, Security, and RDP operational logs manually."
    }
}

function Test-OfflineServices {
    param([string]$ControlSetPath)

    $required = @("Dnscache", "LSM", "Netlogon", "ProfSvc", "LanmanWorkstation", "TermService", "RpcSs", "SessionEnv", "UmRdpService", "BFE", "MpsSvc")
    $disabled = @($required | Where-Object { (Get-RegValue (Join-Path $ControlSetPath "Services\$_") "Start") -eq 4 })
    if ($disabled.Count) {
        Add-Result "Offline service configuration" "Fail" "Disabled: $($disabled -join ', ')." "Restore default startup modes after confirming policy."
    }
    else {
        Add-Result "Offline service configuration" "Pass" "No checked RDP dependency is disabled."
    }
}

function Invoke-OfflineChecks {
    param([string]$WindowsPath)

    if (-not (Test-Administrator)) { throw "Offline mode requires an elevated PowerShell session." }
    $windows = (Resolve-Path -LiteralPath $WindowsPath -ErrorAction Stop).Path.TrimEnd("\")
    $systemFile = Join-Path $windows "System32\Config\SYSTEM"
    $softwareFile = Join-Path $windows "System32\Config\SOFTWARE"
    if (-not (Test-Path $systemFile) -or -not (Test-Path $softwareFile)) { throw "SYSTEM or SOFTWARE hive not found under '$windows'." }

    $systemName = "RdpDiagSystem_$PID"
    $softwareName = "RdpDiagSoftware_$PID"
    $systemLoaded = $false
    $softwareLoaded = $false
    try {
        & reg.exe load "HKLM\$systemName" $systemFile *> $null
        if ($LASTEXITCODE) { throw "Could not load the offline SYSTEM hive." }
        $systemLoaded = $true
        & reg.exe load "HKLM\$softwareName" $softwareFile *> $null
        if ($LASTEXITCODE) { throw "Could not load the offline SOFTWARE hive." }
        $softwareLoaded = $true

        $systemRoot = "Registry::HKEY_LOCAL_MACHINE\$systemName"
        $softwareRoot = "Registry::HKEY_LOCAL_MACHINE\$softwareName"
        $current = Get-RegValue (Join-Path $systemRoot "Select") "Current"
        $controlSet = "ControlSet{0:D3}" -f $(if ($current) { [int]$current } else { 1 })
        $controlSetPath = Join-Path $systemRoot $controlSet
        $name = Get-RegValue (Join-Path $controlSetPath "Control\ComputerName\ComputerName") "ComputerName"
        if ($name) { $script:ComputerName = $name }

        Add-Result "Execution mode" "Information" "Offline inspection of $windows using $controlSet."
        $terminalServer = Join-Path $controlSetPath "Control\Terminal Server"
        $rdpTcp = Join-Path $terminalServer "WinStations\RDP-Tcp"
        $policy = Join-Path $softwareRoot "Policies\Microsoft\Windows NT\Terminal Services"
        Test-RdpConfiguration $terminalServer $rdpTcp $policy
        Test-TermServiceConfiguration (Join-Path $controlSetPath "Services\TermService") $windows
        Test-OfflineServices $controlSetPath
        Test-RecentEvents (Join-Path $windows "System32\winevt\Logs")
        Add-Result "Offline limitations" "Information" "Runtime listener, active firewall, NIC, trust, and private-key state require booting the affected OS."
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        if ($softwareLoaded) { & reg.exe unload "HKLM\$softwareName" *> $null }
        if ($systemLoaded) { & reg.exe unload "HKLM\$systemName" *> $null }
    }
}

function Write-Report {
    if ($OutputPath) {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
        $directory = Split-Path -Parent $resolved
        if ($directory -and -not (Test-Path $directory)) { throw "Output directory '$directory' does not exist." }
        $script:Results | Export-Csv -LiteralPath $resolved -NoTypeInformation -Encoding UTF8
    }

    $failed = @($script:Results | Where-Object Status -eq "Fail")
    $warnings = @($script:Results | Where-Object Status -eq "Warning")
    $overall = if ($failed.Count) { "BLOCKER FOUND" } elseif ($warnings.Count) { "REVIEW WARNINGS" } else { "NO GUEST BLOCKER FOUND" }
    $color = if ($failed.Count) { "Red" } elseif ($warnings.Count) { "Yellow" } else { "Green" }

    Write-Host ""
    Write-Host "RDP: $overall  Computer=$script:ComputerName  Fail=$($failed.Count)  Warn=$($warnings.Count)" -ForegroundColor $color
    foreach ($result in $script:Results) {
        $resultColor = switch ($result.Status) {
            "Fail" { "Red" }
            "Warning" { "Yellow" }
            "Pass" { "Green" }
            default { "Gray" }
        }
        Write-Host "[$($result.Status)] $($result.Check): $($result.Details)" -ForegroundColor $resultColor
        if ($result.Recommendation -ne "None.") { Write-Host "  Action: $($result.Recommendation)" }
    }
    Write-Host "External: validate NSG, routes, NAT/load balancer, JIT/Bastion, VPN, and upstream firewalls."
    if ($OutputPath) { Write-Host "CSV: $resolved" }

    if ($Detailed) { $script:Results }
}

if (Test-Administrator) {
    Add-Result "Administrative context" "Pass" "Running elevated."
}
else {
    Add-Result "Administrative context" "Warning" "Not elevated; some checks may be incomplete." "Use Run Command or an elevated console."
}

if ($OfflineWindowsPath) {
    Invoke-OfflineChecks $OfflineWindowsPath
    Write-Report
    return
}

Add-Result "Execution mode" "Information" "Inspecting the running Windows installation."
$terminalServer = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
$rdpTcp = Join-Path $terminalServer "WinStations\RDP-Tcp"
$policy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
Test-RdpConfiguration $terminalServer $rdpTcp $policy
Test-TermServiceConfiguration "HKLM:\SYSTEM\CurrentControlSet\Services\TermService" $env:SystemRoot
$termService = Test-OnlineServices
Test-OnlineCertificate $rdpTcp
Test-OnlineNetwork $termService
Test-OnlineFirewall
Test-RecentEvents
Write-Report
