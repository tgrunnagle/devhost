#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs a startup task that keeps Windows awake while the devhost VM is running.

.DESCRIPTION
    Copies host/stay-awake.ps1 to %ProgramData%\devhost (locked down so only
    administrators can change it, since it runs as SYSTEM) and registers a scheduled
    task that runs it at startup. The task is started immediately, so no reboot is
    needed.

    Safe to re-run: it replaces the task and the installed copy of the script.

.EXAMPLE
    .\host\Register-StayAwakeTask.ps1

.EXAMPLE
    .\host\Register-StayAwakeTask.ps1 -Unregister
#>
[CmdletBinding()]
param(
    [string]$VMName          = 'devhost',
    [int]   $IntervalSeconds = 60,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

$taskName   = "$VMName stay awake"
$installDir = Join-Path $env:ProgramData 'devhost'
$scriptPath = Join-Path $installDir 'stay-awake.ps1'
$logPath    = Join-Path $installDir 'stay-awake.log'

function Remove-StayAwakeTask {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed scheduled task '$taskName'."
    }
}

if ($Unregister) {
    Remove-StayAwakeTask
    if (Test-Path $installDir) {
        Remove-Item -Recurse -Force $installDir
        Write-Host "Removed $installDir."
    }
    return
}

# Replace any previous version so the running loop picks up the new script.
Remove-StayAwakeTask

# The task runs as SYSTEM, so only SYSTEM and Administrators may change the script.
# Users inherit write access in %ProgramData% by default. SIDs avoid localized names:
# S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators, S-1-5-32-545 = Users.
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
icacls $installDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed to set permissions on $installDir." }
Copy-Item -Path (Join-Path $PSScriptRoot 'stay-awake.ps1') -Destination $scriptPath -Force

$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" " +
             "-VMName `"$VMName`" -IntervalSeconds $IntervalSeconds -LogPath `"$logPath`""
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet `
                -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                       -Principal $principal -Settings $settings `
                       -Description "Keeps Windows awake while the Hyper-V VM '$VMName' is running." | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Host "Registered and started scheduled task '$taskName'." -ForegroundColor Green
Write-Host "  Script: $scriptPath"
Write-Host "  Log:    $logPath"
Write-Host "Check it with (elevated):  powercfg /requests"
