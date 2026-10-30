<#
.SYNOPSIS
    Keeps Windows from sleeping while the devhost VM is running.

.DESCRIPTION
    Hyper-V doesn't count a running VM as activity, so the host's idle-sleep timer
    still fires and freezes the VM. This loop checks the VM every -IntervalSeconds
    and holds a "system required" power request only while it is Running. When the
    VM is stopped, saved or paused, the request is released and the normal power
    plan applies. The display can still turn off.

    Runs as SYSTEM from the scheduled task that host/Register-StayAwakeTask.ps1
    creates; it isn't meant to be started by hand. The active request shows up in
    `powercfg /requests` (elevated) under SYSTEM.
#>
[CmdletBinding()]
param(
    [string]$VMName          = 'devhost',
    [int]   $IntervalSeconds = 60,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DevHostPower {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct REASON_CONTEXT {
        public uint Version;
        public uint Flags;
        [MarshalAs(UnmanagedType.LPWStr)] public string SimpleReasonString;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr PowerCreateRequest(ref REASON_CONTEXT context);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool PowerSetRequest(IntPtr request, int requestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool PowerClearRequest(IntPtr request, int requestType);
}
'@

$POWER_REQUEST_CONTEXT_SIMPLE_STRING = 0x1
$PowerRequestSystemRequired          = 1

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    if ($LogPath) { Add-Content -Path $LogPath -Value $line } else { Write-Host $line }
}

$context = New-Object DevHostPower+REASON_CONTEXT
$context.Version            = 0
$context.Flags              = $POWER_REQUEST_CONTEXT_SIMPLE_STRING
$context.SimpleReasonString = "Hyper-V VM '$VMName' is running"

$request = [DevHostPower]::PowerCreateRequest([ref]$context)
if ($request -eq [IntPtr]::Zero -or $request -eq [IntPtr](-1)) {
    throw "PowerCreateRequest failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
}

Write-Log "Watching VM '$VMName' every $IntervalSeconds s."
$held = $false
while ($true) {
    $vm    = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    $state = if ($vm) { "$($vm.State)" } else { 'missing' }

    if ($state -eq 'Running' -and -not $held) {
        if (-not [DevHostPower]::PowerSetRequest($request, $PowerRequestSystemRequired)) {
            throw "PowerSetRequest failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
        }
        $held = $true
        Write-Log "VM is Running: preventing sleep."
    } elseif ($state -ne 'Running' -and $held) {
        [DevHostPower]::PowerClearRequest($request, $PowerRequestSystemRequired) | Out-Null
        $held = $false
        Write-Log "VM is $($state): allowing sleep."
    }

    Start-Sleep -Seconds $IntervalSeconds
}
