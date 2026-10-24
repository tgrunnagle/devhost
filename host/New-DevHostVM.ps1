#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates the devhost Hyper-V VM: a shared Docker host for dev laptops on the LAN.

.DESCRIPTION
    - Creates an External virtual switch bound to a physical adapter (bridged, so the
      VM gets its own LAN IP). Creating the switch briefly drops this PC's network.
    - Downloads and verifies the Ubuntu Server ISO (or uses -IsoPath).
    - Creates a Generation 2 VM with Secure Boot set for Linux, dynamic memory, a
      dynamic VHDX, a static MAC (for a stable DHCP reservation) and the ISO as the
      first boot device.
    - Sets the VM to start with Windows if it was running at shutdown.

    Settings come from, in increasing priority: built-in defaults, config.psd1 at the
    repo root (see config.example.psd1), and parameters passed to this script.

    Safe to re-run: it stops if the VM already exists and reuses the switch if it
    already exists.

.EXAMPLE
    .\host\New-DevHostVM.ps1

.EXAMPLE
    .\host\New-DevHostVM.ps1 -VMName devhost2 -CpuCount 8 -IsoPath C:\iso\ubuntu.iso
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [string]$VMName,
    [string]$IsoUrl,
    [string]$IsoSha256,
    [string]$IsoPath,
    [string]$VMRoot,
    [string]$SwitchName,
    [string]$NetAdapter,
    [int]   $CpuCount,
    [int]   $CpuWeight,
    [int64] $MemStartup,
    [int64] $MemMinimum,
    [int64] $MemMaximum,
    [int64] $DiskSize
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar

function Get-DevHostSettings {
    param([string]$ConfigPath, [hashtable]$Overrides)

    $settings = @{
        VMName     = 'devhost'
        IsoUrl     = 'https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-live-server-amd64.iso'
        IsoSha256  = 'cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927'
        IsoPath    = $null
        VMRoot     = $null
        SwitchName = 'LAN'
        NetAdapter = $null
        CpuCount   = 4
        CpuWeight  = 50
        MemStartup = 4GB
        MemMinimum = 2GB
        MemMaximum = 8GB
        DiskSize   = 128GB
    }

    if (Test-Path $ConfigPath) {
        Write-Host "Using settings from $((Resolve-Path $ConfigPath).Path)"
        $config = Import-PowerShellDataFile -Path $ConfigPath
        foreach ($key in $config.Keys) {
            if (-not $settings.ContainsKey($key)) { throw "Unknown setting '$key' in $ConfigPath" }
            $settings[$key] = $config[$key]
        }
    }

    foreach ($key in $Overrides.Keys) {
        if ($settings.ContainsKey($key)) { $settings[$key] = $Overrides[$key] }
    }

    if ($settings.MemMinimum -gt $settings.MemStartup -or $settings.MemStartup -gt $settings.MemMaximum) {
        throw 'Memory settings must satisfy MemMinimum <= MemStartup <= MemMaximum.'
    }
    return $settings
}

function Test-IsoHash {
    param([string]$Path, [string]$Expected)
    if (-not $Expected) {
        Write-Warning "No IsoSha256 set; skipping checksum verification of $Path"
        return $true
    }
    Write-Host "Verifying SHA256 of $Path..."
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    return $actual -eq $Expected.ToUpperInvariant()
}

function Resolve-Iso {
    param([hashtable]$Settings, [string]$CacheDir)

    if ($Settings.IsoPath) {
        if (-not (Test-Path $Settings.IsoPath)) { throw "ISO not found: $($Settings.IsoPath)" }
        if (-not (Test-IsoHash $Settings.IsoPath $Settings.IsoSha256)) {
            throw "Checksum mismatch for $($Settings.IsoPath). Wrong file, or IsoSha256 is for a different release."
        }
        return (Resolve-Path $Settings.IsoPath).Path
    }

    if (-not $Settings.IsoUrl) { throw 'Set IsoUrl or IsoPath.' }
    $fileName = [IO.Path]::GetFileName(([Uri]$Settings.IsoUrl).AbsolutePath)
    $isoFile  = Join-Path $CacheDir $fileName

    if (Test-Path $isoFile) {
        if (Test-IsoHash $isoFile $Settings.IsoSha256) { return $isoFile }
        Write-Warning "Cached ISO failed verification; downloading again."
        Remove-Item $isoFile
    }

    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $partial = "$isoFile.partial"
    Write-Host "Downloading $($Settings.IsoUrl)..."
    Invoke-WebRequest -Uri $Settings.IsoUrl -OutFile $partial -UseBasicParsing
    if (-not (Test-IsoHash $partial $Settings.IsoSha256)) {
        Remove-Item $partial
        throw "Downloaded ISO failed checksum verification."
    }
    Move-Item $partial $isoFile
    return $isoFile
}

function Resolve-NetAdapter {
    param([string]$Name)

    if ($Name) {
        if (-not (Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue)) {
            throw "Network adapter '$Name' not found. Check Get-NetAdapter."
        }
        return $Name
    }

    $physical  = Get-NetAdapter -Physical | Where-Object Status -eq 'Up'
    $withRoute = Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway -and ($physical.ifIndex -contains $_.InterfaceIndex) }
    if (@($withRoute).Count -ne 1) {
        throw "Could not pick a network adapter automatically (found $(@($withRoute).Count)). Set NetAdapter in config.psd1."
    }

    $adapter = $physical | Where-Object ifIndex -eq $withRoute.InterfaceIndex
    if ($adapter.PhysicalMediaType -match '802\.11') {
        Write-Warning "'$($adapter.Name)' is Wi-Fi. Bridging over Wi-Fi often fails to get the VM a LAN IP; wired Ethernet is strongly preferred."
    }
    Write-Host "Using network adapter '$($adapter.Name)' ($($adapter.InterfaceDescription))."
    return $adapter.Name
}

# --- Settings and preflight --------------------------------------------------------
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$s = Get-DevHostSettings -ConfigPath $ConfigPath -Overrides $PSBoundParameters

if (Get-VM -Name $s.VMName -ErrorAction SilentlyContinue) {
    throw "A VM named '$($s.VMName)' already exists. Remove it or choose another -VMName."
}
if (-not $s.VMRoot) { $s.VMRoot = (Get-VMHost).VirtualMachinePath }

$iso = Resolve-Iso -Settings $s -CacheDir (Join-Path $repoRoot '.cache')

# --- External switch ---------------------------------------------------------------
$switch = Get-VMSwitch -Name $s.SwitchName -ErrorAction SilentlyContinue
if ($switch) {
    if ($switch.SwitchType -ne 'External') {
        throw "Switch '$($s.SwitchName)' exists but is $($switch.SwitchType), not External."
    }
    Write-Host "Using existing External switch '$($s.SwitchName)'."
} else {
    $adapterName = Resolve-NetAdapter -Name $s.NetAdapter
    Write-Host "Creating External switch '$($s.SwitchName)' on '$adapterName' (network will drop for a few seconds)..."
    New-VMSwitch -Name $s.SwitchName -NetAdapterName $adapterName -AllowManagementOS $true | Out-Null
    # Give the host's vEthernet adapter time to get its DHCP lease back.
    Start-Sleep -Seconds 10
}

# --- VM ----------------------------------------------------------------------------
$vmDir   = Join-Path $s.VMRoot $s.VMName
$vhdPath = Join-Path $vmDir "$($s.VMName).vhdx"
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

Write-Host "Creating VM '$($s.VMName)' in $vmDir..."
New-VM -Name $s.VMName `
       -Generation 2 `
       -Path $s.VMRoot `
       -MemoryStartupBytes $s.MemStartup `
       -NewVHDPath $vhdPath `
       -NewVHDSizeBytes $s.DiskSize `
       -SwitchName $s.SwitchName | Out-Null

Set-VMMemory -VMName $s.VMName -DynamicMemoryEnabled $true `
             -StartupBytes $s.MemStartup -MinimumBytes $s.MemMinimum -MaximumBytes $s.MemMaximum

Set-VMProcessor -VMName $s.VMName -Count $s.CpuCount -RelativeWeight $s.CpuWeight

# Ubuntu boots with Secure Boot using the third-party UEFI CA template.
Set-VMFirmware -VMName $s.VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'

# Static MAC in Hyper-V's 00-15-5D range so a router DHCP reservation keeps working.
$mac = '00155D' + (-join (1..3 | ForEach-Object { '{0:X2}' -f (Get-Random -Maximum 256) }))
Set-VMNetworkAdapter -VMName $s.VMName -StaticMacAddress $mac

# Boot from the ISO first; after install, remove the DVD (see instructions below).
$dvd = Add-VMDvdDrive -VMName $s.VMName -Path $iso -Passthru
$hdd = Get-VMHardDiskDrive -VMName $s.VMName
$nic = Get-VMNetworkAdapter -VMName $s.VMName
Set-VMFirmware -VMName $s.VMName -BootOrder $dvd, $hdd, $nic

# Server-style behavior: start with Windows if it was running, shut down cleanly,
# no automatic checkpoints (they would pile up and slow the disk).
Set-VM -Name $s.VMName `
       -AutomaticStartAction StartIfRunning `
       -AutomaticStartDelay 30 `
       -AutomaticStopAction ShutDown `
       -AutomaticCheckpointsEnabled $false `
       -CheckpointType Production

Enable-VMIntegrationService -VMName $s.VMName -Name 'Guest Service Interface'

# --- Summary -----------------------------------------------------------------------
$macPretty = ($mac -split '(..)' | Where-Object { $_ }) -join ':'
Write-Host ""
Write-Host "VM '$($s.VMName)' created." -ForegroundColor Green
Write-Host "  vCPU:   $($s.CpuCount) (weight $($s.CpuWeight))"
Write-Host "  Memory: $($s.MemMinimum/1GB)-$($s.MemMaximum/1GB) GB dynamic (start $($s.MemStartup/1GB) GB)"
Write-Host "  Disk:   $vhdPath ($($s.DiskSize/1GB) GB dynamic)"
Write-Host "  ISO:    $iso"
Write-Host "  MAC:    $macPretty   <- use this for the DHCP reservation on your router"
Write-Host ""
Write-Host "Next steps (see README.md):"
Write-Host "  1. Start-VM $($s.VMName); vmconnect.exe localhost $($s.VMName)"
Write-Host "  2. In the installer: enable 'Install OpenSSH server'; on the storage screen,"
Write-Host "     grow the ubuntu-lv volume to use the whole disk."
Write-Host "  3. After install, eject the ISO:  Get-VMDvdDrive $($s.VMName) | Remove-VMDvdDrive"
