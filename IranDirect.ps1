#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Send Iranian IPv4 prefixes through the local LAN gateway so they skip SoftEther VPN.

.DESCRIPTION
  SoftEther VPN Client has no "bypass Iran" option. When the VPN is connected, Windows
  typically has a default route via the VPN adapter. This script downloads announced
  Iran IPv4 prefixes and adds more-specific routes via the physical LAN/Wi-Fi gateway.
  Foreign traffic keeps using the VPN default route.

.PARAMETER Action
  Apply          Add Iran-direct routes (download fresh prefix list).
  Remove         Delete routes recorded from the last Apply.
  InstallTask    Register a logon scheduled task that runs Apply.
  UninstallTask  Remove that scheduled task.
  Status         Show LAN gateway, default routes, and applied prefix count.

.NOTES
  Routes are not persistent across reboot. Re-run Apply after restart, or InstallTask.
  Requires Administrator. Prefix list: https://github.com/farshidmousavii/iran-ip-ranges
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Apply', 'Remove', 'InstallTask', 'UninstallTask', 'Status')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$StateDir = Join-Path $env:LOCALAPPDATA 'SoftEtherIranBypass'
$StateFile = Join-Path $StateDir 'applied-cidrs.txt'
$ListUrl = 'https://raw.githubusercontent.com/farshidmousavii/iran-ip-ranges/main/dist/raw/ipv4.txt'
$TaskName = 'SoftEther Iran Direct Routes'

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

function Get-LanGateway {
    param($Adapter)

    $default = Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0' } |
        Select-Object -First 1
    if ($default) { return $default.NextHop }

    $hops = Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' }
    if (-not $hops) { throw "Could not find LAN gateway on adapter $($Adapter.Name)." }

    return ($hops | Group-Object NextHop | Sort-Object Count -Descending | Select-Object -First 1).Name
}

function Get-IranCidrs {
    Write-Host "Downloading Iran IPv4 prefixes..."
    $text = (Invoke-WebRequest -Uri $ListUrl -UseBasicParsing -TimeoutSec 60).Content
    $cidrs = @()
    foreach ($line in ($text -split "`n")) {
        $t = $line.Trim()
        if ($t -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
            $cidrs += $t
        }
    }
    if ($cidrs.Count -lt 50) { throw "Iran prefix list looks empty or invalid ($($cidrs.Count) entries)." }
    Write-Host "Loaded $($cidrs.Count) prefixes."
    return $cidrs
}

function Invoke-Apply {
    $lan = Get-LanAdapter
    $gw = Get-LanGateway -Adapter $lan
    $cidrs = Get-IranCidrs

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $applied = New-Object System.Collections.Generic.List[string]
    $ok = 0
    $skip = 0
    $fail = 0
    $n = 0

    Write-Host "Adding routes via $gw on $($lan.Name) (ifIndex $($lan.ifIndex))..."
    foreach ($cidr in $cidrs) {
        $n++
        if ($n % 200 -eq 0) { Write-Host "  $n / $($cidrs.Count)" }
        $ip, $len = $cidr.Split('/')
        $mask = Convert-CidrToMask -PrefixLength ([int]$len)
        $out = & route.exe add $ip mask $mask $gw METRIC 5 IF $lan.ifIndex 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $out -match 'already exists|The object already exists|The route addition failed: The object already exists') {
            $applied.Add($cidr) | Out-Null
            if ($out -match 'already exists|The object already exists') { $skip++ } else { $ok++ }
        } else {
            $fail++
        }
    }

    $applied | Set-Content -Path $StateFile -Encoding ASCII
    Write-Host "Done. added=$ok already-present=$skip failed=$fail"
    Write-Host "State: $StateFile"
    Write-Host "LAN gateway: $gw"
}

function Invoke-Remove {
    if (-not (Test-Path $StateFile)) {
        Write-Host "No applied-route list found. Nothing to remove."
        return
    }
    $cidrs = Get-Content $StateFile | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' }
    $n = 0
    $ok = 0
    foreach ($cidr in $cidrs) {
        $n++
        if ($n % 200 -eq 0) { Write-Host "  removing $n / $($cidrs.Count)" }
        $ip, $len = $cidr.Split('/')
        $mask = Convert-CidrToMask -PrefixLength ([int]$len)
        & route.exe delete $ip mask $mask | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok++ }
    }
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-Host "Removed $ok routes."
}

function Invoke-InstallTask {
    $scriptPath = $PSCommandPath
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Action Apply"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $t1 = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $t1 -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Scheduled task '$TaskName' installed (runs at logon as admin)."
    Write-Host "After you connect SoftEther, wait a few seconds or run Apply again if needed."
}

function Invoke-UninstallTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Scheduled task '$TaskName' removed."
}

function Invoke-Status {
    $lan = Get-LanAdapter
    $gw = Get-LanGateway -Adapter $lan
    $defaults = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' }
    Write-Host "LAN adapter : $($lan.Name) ifIndex=$($lan.ifIndex)"
    Write-Host "LAN gateway : $gw"
    Write-Host "Default routes:"
    $defaults | Format-Table DestinationPrefix, NextHop, InterfaceAlias, RouteMetric -AutoSize | Out-String | Write-Host
    if (Test-Path $StateFile) {
        $c = (Get-Content $StateFile).Count
        Write-Host "Applied Iran prefixes on file: $c"
    } else {
        Write-Host "No Iran-direct routes recorded yet."
    }
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
