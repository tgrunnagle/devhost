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
| `host/Register-StayAwakeTask.ps1` | Windows host (admin) | Keeps the host awake while the VM runs |
| `config.example.psd1` | Windows host | Template for per-machine settings |
| `guest/install-docker.sh` | VM | Installs and configures Docker Engine |
| `guest/add-dev-user.sh` | VM | Gives a developer SSH + Docker access |
| `client/add-devhost-context.sh` | macOS / Linux laptop | Creates the `devhost` Docker context |
| `client/Add-DevHostContext.ps1` | Windows laptop | Same, for Windows |

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

Which name reaches the VM depends on your router's DNS: often `devhost.lan` (or `devhost.local`, `devhost.home`) rather than plain `devhost`. Check with `nslookup devhost.lan`, and use the VM's reserved IP if no name resolves reliably. Then:

```bash
docker --context devhost ps      # one-off
docker context use devhost       # make it the default
```

Your SSH key must load without a prompt (via ssh-agent, or no passphrase), because Docker can't answer SSH prompts.

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

The VM starts with Windows if it was running at shutdown. Containers started with `--restart unless-stopped` come back after the VM restarts. While the VM is off or saved, developers' `docker` commands fail until it's started again.

### Keep the host awake while the VM runs

Windows doesn't count a running VM as activity, so the host still goes to sleep on its idle timer and the VM freezes with it. Install a startup task that prevents sleep only while the VM is running:

```powershell
.\host\Register-StayAwakeTask.ps1               # elevated; starts immediately, no reboot
.\host\Register-StayAwakeTask.ps1 -Unregister   # remove it
```

The task runs `stay-awake.ps1` as SYSTEM from `%ProgramData%\devhost` and checks the VM every minute. While the VM is stopped, saved or paused, your normal power plan applies. The display still turns off as usual, and choosing **Sleep** from the Start menu still works (taking the VM offline with it).

To confirm it's working, run `powercfg /requests` in an elevated prompt: under **SYSTEM** you should see `Hyper-V VM 'devhost' is running`. Transitions are logged to `%ProgramData%\devhost\stay-awake.log`.
