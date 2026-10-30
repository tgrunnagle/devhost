<#
.SYNOPSIS
    Points a dev laptop's Docker CLI at devhost over SSH (Windows).

.DESCRIPTION
    Requires the Docker CLI, the Windows OpenSSH client, and an SSH key the host
    already trusts (see guest/add-dev-user.sh). The key must load without a prompt
    (ssh-agent or no passphrase), because Docker can't answer SSH prompts.

    Also offers to add a Host block for -HostName to ~/.ssh/config, so sessions to
    a VM that has gone away are dropped instead of hanging.

.EXAMPLE
    .\client\Add-DevHostContext.ps1 -HostName devhost -User alice
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HostName,
    [Parameter(Mandatory)][string]$User,
    [string]$Name = 'devhost'
)

$ErrorActionPreference = 'Stop'
$target = "$User@$HostName"

Write-Host "==> Checking SSH access to $target"
# accept-new records the host key on first connect so later Docker calls don't prompt.
ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new $target docker version --format '{{.Server.Version}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not run docker on $target over SSH. Check that your key is authorized and that $User is in the docker group on the host."
}

# Avoids redirecting native stderr, which Windows PowerShell 5.1 turns into a terminating error here.
if ((docker context ls --format '{{.Name}}') -contains $Name) {
    Write-Host "==> Updating existing context '$Name'"
    docker context update $Name --docker "host=ssh://$target"
} else {
    Write-Host "==> Creating context '$Name'"
    docker context create $Name --description 'Shared LAN Docker host' --docker "host=ssh://$target"
}
if ($LASTEXITCODE -ne 0) { throw "docker context command failed." }

$sshConfig = Join-Path $HOME '.ssh\config'
# Keyed by host, so re-running with a different host (say, the IP instead of a
# flaky DNS name) adds a block for it instead of tripping over the old one.
$begin = "# BEGIN devhost $HostName"
$end = "# END devhost $HostName"
# Docker passes its own ConnectTimeout=30 on the ssh command line, which wins over
# this file, so ConnectTimeout here only speeds up plain ssh. The keepalives drop
# sessions to a VM that went away. Windows OpenSSH has no ControlMaster support.
$block = @(
    $begin
    "Host $HostName"
    '  ConnectTimeout 3'
    '  ServerAliveInterval 15'
    '  ServerAliveCountMax 3'
    $end
)

$lines = @()
if (Test-Path $sshConfig) { $lines = @(Get-Content $sshConfig) }
$existing = @()
$inBlock = $false
foreach ($line in $lines) {
    if ($line -eq $begin) { $inBlock = $true }
    if ($inBlock) { $existing += $line }
    if ($line -eq $end) { $inBlock = $false }
}
$hasHost = [bool]($lines | Where-Object { $_ -match '^\s*Host(?:\s*=\s*|\s+)(.+)$' -and (-split $Matches[1]) -contains $HostName })

function Write-Block { Write-Host ""; $block | ForEach-Object { Write-Host $_ }; Write-Host "" }

if (($existing -join "`n") -ceq ($block -join "`n")) {
    Write-Host "==> $sshConfig already has the devhost block for $HostName"
} elseif ($existing.Count -gt 0) {
    Write-Host "==> $sshConfig has an edited devhost block for $HostName; leaving it alone."
    Write-Host "    The script would write:"
    Write-Block
} elseif ($hasHost) {
    Write-Host "==> $sshConfig already has a Host entry for $HostName; leaving it alone."
    Write-Host "    Consider adding these settings to it:"
    Write-Block
} else {
    $answer = 'y'
    if ($lines.Count -gt 0) {
        $answer = 'n'
        if (-not [Console]::IsInputRedirected) {
            $answer = Read-Host "==> Add a devhost Host block to $sshConfig? [y/N]"
        }
    }
    if ($answer -match '^[yY]') {
        New-Item -ItemType Directory -Force (Split-Path $sshConfig) | Out-Null
        # Appended, not prepended: options at the top of the file apply to every host.
        $text = ($block -join "`r`n") + "`r`n"
        if ($lines.Count -gt 0) { $text = "`r`n" + $text }
        # No BOM: OpenSSH doesn't expect one.
        [IO.File]::AppendAllText($sshConfig, $text, (New-Object Text.UTF8Encoding $false))
        Write-Host "==> Added the devhost block to $sshConfig"
    } else {
        Write-Host "==> Not changing $sshConfig. Add this block yourself:"
        Write-Block
    }
}

Write-Host ""
Write-Host "Use it for one command:   docker --context $Name ps"
Write-Host "Or only when reachable:   if (.\client\Test-DevHost.ps1 $Name) { `$env:DOCKER_CONTEXT = '$Name' }"
