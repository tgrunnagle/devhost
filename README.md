# devhost

Provision a Hyper-V Ubuntu VM as a shared Docker host for dev laptops on the LAN, with access over SSH.

Developers run `docker`, `docker build` and `docker compose` from their own laptops; the containers run on the VM, and published ports are reachable at the VM's LAN IP.

```
 dev laptop ──ssh──┐
 dev laptop ──ssh──┼──▶  devhost VM (Ubuntu + Docker Engine)  ◀── bridged onto the LAN
 dev laptop ──ssh──┘        on a Windows Hyper-V host
```

## Layout

| Path | Runs on | Purpose |
|---|---|---|
| `host/New-DevHostVM.ps1` | Windows host (admin) | Creates the External switch and the VM |
| `config.example.psd1` | Windows host | Template for per-machine settings |
| `guest/install-docker.sh` | VM | Installs and configures Docker Engine |
| `guest/add-dev-user.sh` | VM | Gives a developer SSH + Docker access |
| `client/add-devhost-context.sh` | macOS / Linux laptop | Creates the `devhost` Docker context |
| `client/Add-DevHostContext.ps1` | Windows laptop | Same, for Windows |
| `client/devhost-probe.sh` | macOS / Linux laptop | Exits 0 if devhost answers within 5s |
| `client/Test-DevHost.ps1` | Windows laptop | Same, for Windows |

## Requirements

- Windows 10/11 Pro, Enterprise or Education, or Windows Server, with Hyper-V enabled
- A wired network adapter (bridging a VM over Wi-Fi is unreliable)
- Your account in the **Hyper-V Administrators** group, to manage the VM without elevation:
  ```powershell
  # elevated PowerShell, then sign out and back in
  Add-LocalGroupMember -Group "Hyper-V Administrators" -Member "$env:COMPUTERNAME\$env:USERNAME"
  ```

## 1. Create the VM (Windows host)

```powershell
Copy-Item config.example.psd1 config.psd1   # then edit sizing, VMRoot, IsoPath...
.\host\New-DevHostVM.ps1                    # from an elevated PowerShell
```

Settings come from the script's defaults, then `config.psd1`, then command-line parameters (e.g. `-CpuCount 8`). The ISO is downloaded once to `.cache/` and verified against `IsoSha256`; set `IsoPath` to use one you already have.

Creating the External switch drops the host's network for a few seconds. Afterwards the host's connection runs through a `vEthernet (LAN)` adapter; its IP normally stays the same.

The script prints the VM's MAC address. **Reserve an IP for it on your router** so laptops always find the host at the same address.

## 2. Install Ubuntu (VM console)

```powershell
Start-VM devhost; vmconnect.exe localhost devhost
```

In the installer:
- Tick **Install OpenSSH server**.
- On the storage screen, the default LVM layout uses only part of the disk. Edit `ubuntu-lv` and grow it to the maximum.

After the install finishes and the VM reboots, eject the ISO:

```powershell
Get-VMDvdDrive devhost | Remove-VMDvdDrive
```

## 3. Install Docker (inside the VM)

Copy the `guest/` scripts to the VM (e.g. `scp -r guest you@devhost:`), then:

```bash
sudo ./guest/install-docker.sh
```

This installs Docker Engine, Buildx and Compose from Docker's apt repository, rotates container logs (10 MB × 3 per container), raises sshd's session limits for Docker over SSH, and adds you to the `docker` group.

## 4. Add developers (inside the VM)

Get each developer's SSH **public** key (e.g. `~/.ssh/id_ed25519.pub`), copy it to the VM, and run:

```bash
sudo ./guest/add-dev-user.sh alice alice.pub
```

> **Security:** anyone in the `docker` group is effectively root on the VM. Only add people you trust, and don't expose the VM beyond your LAN.

## 5. Connect a laptop

macOS / Linux:
```bash
./client/add-devhost-context.sh devhost alice
```

Windows:
```powershell
.\client\Add-DevHostContext.ps1 -HostName devhost -User alice
```

Which name reaches the VM depends on your router's DNS: often `devhost.lan` (or `devhost.local`, `devhost.home`) rather than plain `devhost`. Check with `nslookup devhost.lan`, and use the VM's reserved IP if no name resolves reliably.

Your SSH key must load without a prompt (via ssh-agent, or no passphrase), because Docker can't answer SSH prompts.

The script also offers to add a `Host` block for the VM to `~/.ssh/config`. It asks before changing an existing file, and re-running it doesn't add a second copy. If it finds a block you've edited, or your own `Host` entry for the VM, it leaves the file alone and prints the settings instead:

```
Host 192.168.1.50
  ConnectTimeout 3          # plain ssh fails fast when the VM is down
  ServerAliveInterval 15    # drop sessions to a VM that went away within ~45s
  ServerAliveCountMax 3
  ControlMaster auto        # docker calls share one SSH connection (not on Windows)
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

Docker passes its own `-o ConnectTimeout=30` to ssh, which overrides `ConnectTimeout` from this file. A docker call to a VM that doesn't answer can therefore still take up to 30s to fail. Use the probe below to avoid that.

### Use devhost only when it's reachable

Avoid `docker context use devhost`. It makes devhost the default for every docker command, including the ones that IDEs, prompts and test setups run on their own. While the VM is saved, stopped or off the network, each of those commands stalls until SSH gives up, and that keeps happening until you switch the context back. Opt in per command or per session instead:

```bash
# one-off
DOCKER_CONTEXT=devhost docker compose up -d
docker --context devhost ps

# shell rc file or .envrc (direnv): only when the daemon answers
/path/to/devhost/client/devhost-probe.sh && export DOCKER_CONTEXT=devhost
```

```powershell
# PowerShell profile
if (C:\path\to\devhost\client\Test-DevHost.ps1) { $env:DOCKER_CONTEXT = 'devhost' }
```

`devhost-probe.sh [context]` runs `docker --context devhost version` and exits 0 if the daemon answers, or 1 otherwise. It never takes longer than 5s (set `DEVHOST_PROBE_TIMEOUT` to change that), even without the SSH config above.

For Claude Code, a `SessionStart` hook in `.claude/settings.json` can point the session at devhost only when the VM is up. It prints a one-line note for the agent on success and nothing otherwise:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if /path/to/devhost/client/devhost-probe.sh; then echo 'export DOCKER_CONTEXT=devhost' >> \"$CLAUDE_ENV_FILE\"; echo 'devhost is reachable: docker commands in this session run on the shared devhost VM (DOCKER_CONTEXT=devhost).'; fi"
          }
        ]
      }
    ]
  }
}
```

## Using the shared host

- **Ports:** `docker run -p 8080:80 …` is reachable at `http://devhost:8080`. Agree on port ranges per developer to avoid collisions.
- **Bind mounts refer to the VM's filesystem, not your laptop.** `-v ./src:/app` mounts a folder on the VM. Bake code into images or use named volumes. `docker build` works normally; the build context is uploaded from your laptop.
- **Firewall:** ports published by Docker bypass `ufw`, because Docker manages iptables directly. Keep the VM on a trusted network.
- **Cleanup:** images and build cache add up on a shared host. Run `docker system prune` periodically.

## Operating the VM (Windows host)

| Want to | Run |
|---|---|
| Pause it and free all CPU/RAM (resumes as-is) | `Save-VM devhost` |
| Shut it down cleanly | `Stop-VM devhost` |
| Start it | `Start-VM devhost` |
| Throttle CPU without stopping | `Set-VMProcessor devhost -Maximum 25` (`-Maximum 100` to undo) |
| Change memory limits | `Set-VMMemory devhost -MaximumBytes 32GB` |
| Grow the disk | `Resize-VHD <path>.vhdx -SizeBytes 400GB`, then grow the partition and LVM in the VM |

The VM starts with Windows if it was running at shutdown. Containers started with `--restart unless-stopped` come back after the VM restarts. While the VM is off or saved, developers' `docker` commands against devhost fail until it's started again.

## Troubleshooting

### Docker commands hang

The `devhost` context is selected (by `DOCKER_CONTEXT=devhost` or `docker context use devhost`) while the VM is saved, stopped or unreachable. Every docker command then waits for SSH to give up (up to 30s each), and this continues until you unset the context:

```bash
unset DOCKER_CONTEXT          # PowerShell: Remove-Item Env:DOCKER_CONTEXT
docker context use default    # if you ran `docker context use devhost`
```

Then opt in only when the VM is reachable (see [Use devhost only when it's reachable](#use-devhost-only-when-its-reachable)). Other things to check:

- **Long-running commands** (`docker events`, `logs -f`, an attached `compose up`) that hang after the VM was saved need `ServerAliveInterval` in `~/.ssh/config`. Without it, SSH never notices that the VM is gone.
- **Stale shared connection (macOS / Linux):** with `ControlMaster`, new docker calls reuse the connection left open from earlier calls. If the VM went away, they hang until the keepalives drop that connection (about 45s), and Docker's 30s connect timeout doesn't apply. Close it right away with `ssh -O exit 192.168.1.50` (the host from your context).
- **DNS:** names like `devhost.lan` can stall when the router isn't sure about them. Point the context at the IP from the VM's reserved DHCP lease instead: `./client/add-devhost-context.sh 192.168.1.50 alice`.
