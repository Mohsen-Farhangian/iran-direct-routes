#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Send Iranian IPv4/IPv6 prefixes through the local LAN gateway so they skip any full-tunnel VPN.

.DESCRIPTION
  When a VPN (SoftEther, OpenVPN, WireGuard, AnyConnect, etc.) is connected, Windows
  typically has a default route via the VPN adapter. This script downloads announced
  Iran IPv4 and IPv6 prefixes and adds more-specific routes via the physical LAN/Wi-Fi
  gateway. Foreign traffic keeps using the VPN default route. Works on the Windows
  routing table; it does not change the VPN app itself.

  IPv6 routes are applied only when an IPv6 LAN gateway is available. If the NIC has
  no IPv6 gateway, Apply still succeeds for IPv4 and skips IPv6 with a warning.

.PARAMETER Action
  Apply          Add Iran-direct routes (download fresh prefix lists).
  Remove         Delete routes recorded from the last Apply.
  InstallTask    Register a logon scheduled task that runs Apply.
  UninstallTask  Remove that scheduled task.
  Status         Show LAN gateways, default routes, and applied prefix counts.

.NOTES
  Routes are not persistent across reboot. Re-run Apply after restart, or InstallTask.
  Requires Administrator. Prefix lists: https://github.com/farshidmousavii/iran-ip-ranges
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Apply', 'Remove', 'InstallTask', 'UninstallTask', 'Status')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$StateDir = Join-Path $env:LOCALAPPDATA 'IranDirectRoutes'
$LegacyStateDir = Join-Path $env:LOCALAPPDATA 'SoftEtherIranBypass'
$StateFileV4 = Join-Path $StateDir 'applied-ipv4.txt'
$StateFileV6 = Join-Path $StateDir 'applied-ipv6.txt'
$LegacyStateFile = Join-Path $LegacyStateDir 'applied-cidrs.txt'
$LegacyStateFileAlt = Join-Path $StateDir 'applied-cidrs.txt'
$ListUrlV4 = 'https://raw.githubusercontent.com/farshidmousavii/iran-ip-ranges/main/dist/raw/ipv4.txt'
$ListUrlV6 = 'https://raw.githubusercontent.com/farshidmousavii/iran-ip-ranges/main/dist/raw/ipv6.txt'
$TaskName = 'Iran Direct Routes'
$LegacyTaskName = 'SoftEther Iran Direct Routes'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Convert-CidrToMask {
    param([int]$PrefixLength)
    $bits = ('1' * $PrefixLength).PadRight(32, '0')
    $bytes = 0..3 | ForEach-Object { [Convert]::ToByte($bits.Substring($_ * 8, 8), 2) }
    return ($bytes -join '.')
}

function Get-LanAdapter {
    $adapters = Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'VPN Client|TAP-Windows|Wintun|WireGuard|OpenVPN|SoftEther'
    }
    if (-not $adapters) { throw 'No physical LAN/Wi-Fi adapter is up.' }

    $ethernet = $adapters | Where-Object { $_.Name -eq 'Ethernet' } | Select-Object -First 1
    if ($ethernet) { return $ethernet }
    return $adapters | Select-Object -First 1
}

function Get-LanGatewayV4 {
    param($Adapter)

    $default = Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0' } |
        Select-Object -First 1
    if ($default) { return $default.NextHop }

    $hops = Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' }
    if (-not $hops) { throw "Could not find IPv4 LAN gateway on adapter $($Adapter.Name)." }

    return ($hops | Group-Object NextHop | Sort-Object Count -Descending | Select-Object -First 1).Name
}

function Get-LanGatewayV6 {
    param($Adapter)

    $default = Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DestinationPrefix -eq '::/0' -and
            $_.NextHop -and
            $_.NextHop -ne '::'
        } |
        Select-Object -First 1
    if ($default) { return $default.NextHop }

    $hops = Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.NextHop -and
            $_.NextHop -ne '::' -and
            $_.DestinationPrefix -ne 'ff00::/8'
        }
    if (-not $hops) { return $null }

    return ($hops | Group-Object NextHop | Sort-Object Count -Descending | Select-Object -First 1).Name
}

function Get-IranCidrsV4 {
    Write-Host "Downloading Iran IPv4 prefixes..."
    $text = (Invoke-WebRequest -Uri $ListUrlV4 -UseBasicParsing -TimeoutSec 60).Content
    $cidrs = @()
    foreach ($line in ($text -split "`n")) {
        $t = $line.Trim()
        if ($t -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
            $cidrs += $t
        }
    }
    if ($cidrs.Count -lt 50) { throw "Iran IPv4 prefix list looks empty or invalid ($($cidrs.Count) entries)." }
    Write-Host "Loaded $($cidrs.Count) IPv4 prefixes."
    return $cidrs
}

function Get-IranCidrsV6 {
    Write-Host "Downloading Iran IPv6 prefixes..."
    $text = (Invoke-WebRequest -Uri $ListUrlV6 -UseBasicParsing -TimeoutSec 60).Content
    $cidrs = @()
    foreach ($line in ($text -split "`n")) {
        $t = $line.Trim()
        if ($t -match '^[0-9a-fA-F:]+/\d{1,3}$') {
            $cidrs += $t
        }
    }
    if ($cidrs.Count -lt 10) { throw "Iran IPv6 prefix list looks empty or invalid ($($cidrs.Count) entries)." }
    Write-Host "Loaded $($cidrs.Count) IPv6 prefixes."
    return $cidrs
}

function Add-IranRoutesV4 {
    param($Adapter, [string]$Gateway, [string[]]$Cidrs)

    $applied = New-Object System.Collections.Generic.List[string]
    $ok = 0
    $skip = 0
    $fail = 0
    $n = 0

    Write-Host "Adding IPv4 routes via $Gateway on $($Adapter.Name) (ifIndex $($Adapter.ifIndex))..."
    foreach ($cidr in $Cidrs) {
        $n++
        if ($n % 200 -eq 0) { Write-Host "  IPv4 $n / $($Cidrs.Count)" }
        $ip, $len = $cidr.Split('/')
        $mask = Convert-CidrToMask -PrefixLength ([int]$len)
        $out = & route.exe add $ip mask $mask $Gateway METRIC 5 IF $Adapter.ifIndex 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $out -match 'already exists|The object already exists|The route addition failed: The object already exists') {
            $applied.Add($cidr) | Out-Null
            if ($out -match 'already exists|The object already exists') { $skip++ } else { $ok++ }
        } else {
            $fail++
        }
    }

    $applied | Set-Content -Path $StateFileV4 -Encoding ASCII
    Write-Host "IPv4 done. added=$ok already-present=$skip failed=$fail"
    Write-Host "IPv4 state: $StateFileV4"
}

function Add-IranRoutesV6 {
    param($Adapter, [string]$Gateway, [string[]]$Cidrs)

    $applied = New-Object System.Collections.Generic.List[string]
    $ok = 0
    $skip = 0
    $fail = 0
    $n = 0

    Write-Host "Adding IPv6 routes via $Gateway on $($Adapter.Name) (ifIndex $($Adapter.ifIndex))..."
    foreach ($cidr in $Cidrs) {
        $n++
        if ($n % 200 -eq 0) { Write-Host "  IPv6 $n / $($Cidrs.Count)" }
        $out = & route.exe -6 add $cidr $Gateway METRIC 5 IF $Adapter.ifIndex 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $out -match 'already exists|The object already exists|The route addition failed: The object already exists') {
            $applied.Add($cidr) | Out-Null
            if ($out -match 'already exists|The object already exists') { $skip++ } else { $ok++ }
        } else {
            # Fallback: New-NetRoute (some Windows builds prefer this for IPv6)
            try {
                $existing = Get-NetRoute -DestinationPrefix $cidr -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
                if ($existing) {
                    $applied.Add($cidr) | Out-Null
                    $skip++
                } else {
                    New-NetRoute -DestinationPrefix $cidr -InterfaceIndex $Adapter.ifIndex -NextHop $Gateway -RouteMetric 5 -ErrorAction Stop | Out-Null
                    $applied.Add($cidr) | Out-Null
                    $ok++
                }
            } catch {
                $fail++
            }
        }
    }

    $applied | Set-Content -Path $StateFileV6 -Encoding ASCII
    Write-Host "IPv6 done. added=$ok already-present=$skip failed=$fail"
    Write-Host "IPv6 state: $StateFileV6"
}

function Invoke-Apply {
    $lan = Get-LanAdapter
    $gw4 = Get-LanGatewayV4 -Adapter $lan
    $cidrs4 = Get-IranCidrsV4

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Add-IranRoutesV4 -Adapter $lan -Gateway $gw4 -Cidrs $cidrs4
    Write-Host "IPv4 LAN gateway: $gw4"

    $gw6 = Get-LanGatewayV6 -Adapter $lan
    if (-not $gw6) {
        Write-Host "IPv6 skipped: no IPv6 LAN gateway on $($lan.Name). Enable IPv6 on the NIC/router, then run Apply again."
        if (Test-Path $StateFileV6) { Remove-Item $StateFileV6 -Force -ErrorAction SilentlyContinue }
        return
    }

    $cidrs6 = Get-IranCidrsV6
    Add-IranRoutesV6 -Adapter $lan -Gateway $gw6 -Cidrs $cidrs6
    Write-Host "IPv6 LAN gateway: $gw6"
}

function Get-StateFilesToRemove {
    $files = @()
    foreach ($f in @($StateFileV4, $StateFileV6, $LegacyStateFileAlt, $LegacyStateFile)) {
        if ((Test-Path $f) -and ($files -notcontains $f)) {
            $files += $f
        }
    }
    return $files
}

function Invoke-Remove {
    $files = Get-StateFilesToRemove
    if (-not $files -or $files.Count -eq 0) {
        Write-Host "No applied-route list found. Nothing to remove."
        return
    }

    $ok4 = 0
    $ok6 = 0
    foreach ($file in $files) {
        $cidrs = Get-Content $file | Where-Object { $_.Trim() -ne '' }
        $n = 0
        foreach ($cidr in $cidrs) {
            $n++
            if ($n % 200 -eq 0) { Write-Host "  removing $n from $(Split-Path $file -Leaf)" }
            if ($cidr -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
                $ip, $len = $cidr.Split('/')
                $mask = Convert-CidrToMask -PrefixLength ([int]$len)
                & route.exe delete $ip mask $mask | Out-Null
                if ($LASTEXITCODE -eq 0) { $ok4++ }
            } elseif ($cidr -match '^[0-9a-fA-F:]+/\d{1,3}$') {
                & route.exe -6 delete $cidr | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $ok6++
                } else {
                    try {
                        Get-NetRoute -DestinationPrefix $cidr -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                        $ok6++
                    } catch { }
                }
            }
        }
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Removed IPv4=$ok4 IPv6=$ok6 routes."
}

function Invoke-InstallTask {
    $scriptPath = $PSCommandPath
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Action Apply"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $t1 = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $t1 -Principal $principal -Settings $settings -Force | Out-Null
    Unregister-ScheduledTask -TaskName $LegacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Scheduled task '$TaskName' installed (runs at logon as admin)."
    Write-Host "After you connect the VPN, wait a few seconds or run Apply again if needed."
}

function Invoke-UninstallTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $LegacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Scheduled task '$TaskName' removed."
}

function Invoke-Status {
    $lan = Get-LanAdapter
    $gw4 = Get-LanGatewayV4 -Adapter $lan
    $gw6 = Get-LanGatewayV6 -Adapter $lan
    $defaults4 = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' }
    $defaults6 = Get-NetRoute -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq '::/0' }

    Write-Host "LAN adapter : $($lan.Name) ifIndex=$($lan.ifIndex)"
    Write-Host "IPv4 gateway: $gw4"
    if ($gw6) { Write-Host "IPv6 gateway: $gw6" } else { Write-Host "IPv6 gateway: (none)" }
    Write-Host "IPv4 default routes:"
    $defaults4 | Format-Table DestinationPrefix, NextHop, InterfaceAlias, RouteMetric -AutoSize | Out-String | Write-Host
    Write-Host "IPv6 default routes:"
    if ($defaults6) {
        $defaults6 | Format-Table DestinationPrefix, NextHop, InterfaceAlias, RouteMetric -AutoSize | Out-String | Write-Host
    } else {
        Write-Host "(none)"
    }

    $v4 = 0
    $v6 = 0
    if (Test-Path $StateFileV4) { $v4 = (Get-Content $StateFileV4).Count }
    elseif (Test-Path $LegacyStateFileAlt) { $v4 = (Get-Content $LegacyStateFileAlt | Where-Object { $_ -match '^\d' }).Count }
    elseif (Test-Path $LegacyStateFile) { $v4 = (Get-Content $LegacyStateFile | Where-Object { $_ -match '^\d' }).Count }
    if (Test-Path $StateFileV6) { $v6 = (Get-Content $StateFileV6).Count }
    Write-Host "Applied Iran prefixes on file: IPv4=$v4 IPv6=$v6"
}

if (-not (Test-Admin)) {
    throw 'Run this script from an elevated PowerShell (Run as administrator).'
}

switch ($Action) {
    'Apply' { Invoke-Apply }
    'Remove' { Invoke-Remove }
    'InstallTask' { Invoke-InstallTask }
    'UninstallTask' { Invoke-UninstallTask }
    'Status' { Invoke-Status }
}
