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
| `guest/add-dev-user.sh` | VM | Gives a developer SSH access and their own rootless Docker daemon |
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

This installs Docker Engine, Buildx and Compose from Docker's apt repository, rotates container logs (10 MB × 3 per container), raises sshd's session limits for Docker over SSH, and adds you to the `docker` group. It also prepares the VM for per-user rootless daemons (step 4): the rootless extras, an AppArmor profile that lets `rootlesskit` create user namespaces, cgroup v2 controller delegation to user services, and the iptables kernel modules kind needs.

It's safe to re-run, and you need to re-run it on a VM set up before per-user daemons existed.

## 4. Add developers (inside the VM)

Get each developer's SSH **public** key (e.g. `~/.ssh/id_ed25519.pub`), copy it to the VM, and run:

```bash
sudo ./guest/add-dev-user.sh alice alice.pub
```

Each developer gets their own **rootless Docker daemon**, which runs as their user on the VM. They aren't in the `docker` group. `DOCKER_HOST` in their `~/.ssh/environment` points SSH sessions at their own daemon, so their laptop's Docker context reaches it with no extra setup. Each rootless daemon gets the same log rotation as the shared one, via `~/.config/docker/daemon.json`.

**Upgrading an existing VM:** re-run `install-docker.sh`, then `add-dev-user.sh` for each developer. That switches them to rootless mode and removes them from the `docker` group. Containers they started on the shared daemon keep running and holding their ports, but they can no longer see them, so remove those first (`sudo docker ps -a`, `sudo docker rm -f …`). Their images and volumes don't move over either. If a developer was logged in during the upgrade, their session doesn't get cgroup delegation until `sudo systemctl restart user@<uid>.service` or a reboot. The script warns when this applies.

### Shared daemon (opt-in)

```bash
sudo ./guest/add-dev-user.sh --shared alice alice.pub
```

This adds the user to the `docker` group, so they use the VM's single rootful daemon. If they had a rootless daemon, it's stopped; its data stays in `~/.local/share/docker`. Everyone in shared mode shares containers, volumes, networks, images, build cache and Compose project names, and can see and remove each other's. The upside is one copy of each image and one build cache. Users in different modes don't see each other's resources.

> **Security:** anyone in the `docker` group is effectively root on the VM. Rootless users aren't: a `--privileged` container that mounts `/` still runs as the developer's own UID and can't change anything they couldn't change anyway. Only add people you trust, and don't expose the VM beyond your LAN.

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

- **Your own daemon:** containers, volumes, networks, images, build cache and Compose projects are per developer. Two people running `docker compose up` from checkouts with the same directory name get separate projects, and fixed names (`--name`, named volumes, kind clusters) don't collide. `docker system prune`, `docker volume prune` and `docker compose down -v` only touch your own resources.
- **Ports are still shared.** Every daemon publishes on the VM's one network stack, so two developers can't both publish host port `6379`; the second gets `port is already allocated`. Binding to `127.0.0.1` doesn't help, because that's the VM's loopback. Prefer ephemeral host ports (`-p 127.0.0.1::6379`, then `docker port <container>` to find it). For ports that must be fixed, agree on a port range per developer. `docker run -p 8080:80 …` is reachable at `http://devhost:8080`.
- **No ports below 1024 in rootless mode.** Publish `8080:80`, not `80:80`. To allow low ports for everyone, set `net.ipv4.ip_unprivileged_port_start=0` with `sysctl` on the VM.
- **Bind mounts refer to the VM's filesystem, not your laptop.** `-v ./src:/app` mounts a folder on the VM. Bake code into images or use named volumes. `docker build` works normally; the build context is uploaded from your laptop.
- **kind:** works on rootless Docker because `install-docker.sh` delegates cgroup v2 controllers to user services (`Delegate=` in `user@.service`) and loads the iptables modules. Cluster names are per developer. kind ignores `docker --context`, so run `docker context use devhost` (or set `DOCKER_CONTEXT=devhost`) first. `kind create cluster` run from your laptop writes the kubeconfig on your laptop, but publishes the API server on the VM's `127.0.0.1`. Forward that port before running `kubectl`: `ssh -N -L <port>:127.0.0.1:<port> alice@devhost`, with the port from the kubeconfig's `server: https://127.0.0.1:<port>` line.
- **Firewall:** ports published by the shared daemon bypass `ufw`, because Docker manages iptables directly. Rootless daemons publish ports through ordinary listening sockets, so `ufw` rules do apply to them. Keep the VM on a trusted network either way.
- **Disk:** every developer pulls and builds their own images, under `~/.local/share/docker` on the VM, so disk use grows with the number of developers. Run `docker system prune` periodically; it only cleans up your own daemon. To see usage per developer, run `sudo du -sh /home/*/.local/share/docker` on the VM. Users in shared mode share one copy of each image.

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
