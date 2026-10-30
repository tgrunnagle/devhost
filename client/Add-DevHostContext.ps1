<#
.SYNOPSIS
    Points a dev laptop's Docker CLI at devhost over SSH (Windows).

.DESCRIPTION
    Requires the Docker CLI, the Windows OpenSSH client, and an SSH key the host
    already trusts (see guest/add-dev-user.sh). The key must load without a prompt
    (ssh-agent or no passphrase), because Docker can't answer SSH prompts.

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
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new $target docker version --format '{{.Server.Version}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not run docker on $target over SSH. Check that your key is authorized and that $User was set up with guest/add-dev-user.sh on the host."
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

Write-Host ""
Write-Host "Use it for one command:   docker --context $Name ps"
Write-Host "Or make it the default:   docker context use $Name"
