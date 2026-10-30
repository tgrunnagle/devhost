<#
.SYNOPSIS
    Checks whether devhost's Docker daemon answers within a few seconds.

.DESCRIPTION
    Writes $true and exits 0 if the daemon answers, otherwise writes $false and
    exits 1. Never blocks longer than -TimeoutSeconds, even when SSH would hang,
    so profiles and agent hooks can opt into devhost only when it's reachable.

.EXAMPLE
    if (.\client\Test-DevHost.ps1) { $env:DOCKER_CONTEXT = 'devhost' }
#>
[CmdletBinding()]
param(
    [string]$Name = 'devhost',
    [int]$TimeoutSeconds = 5
)

$psi = New-Object Diagnostics.ProcessStartInfo 'docker', "--context `"$Name`" version --format `"{{.Server.Version}}`""
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$proc = [Diagnostics.Process]::Start($psi)
$ok = $proc.WaitForExit($TimeoutSeconds * 1000) -and $proc.ExitCode -eq 0
if (-not $proc.HasExited) { $proc.Kill() }

$ok
exit [int](-not $ok)
