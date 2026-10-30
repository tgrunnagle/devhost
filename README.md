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
| `client/devhost` | macOS / Linux laptop | Helper commands: `devhost lock` for host-wide locks |
| `tests/devhost-lock.test.sh` | Linux | Tests for `devhost lock` (fake `ssh`, no VM needed) |
| `tests/devhost-lock.e2e.sh` | Disposable container | End-to-end `devhost lock` test with a real sshd (see its header) |

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

This installs Docker Engine, Buildx and Compose from Docker's apt repository, rotates container logs (10 MB × 3 per container), raises sshd's session limits for Docker over SSH, sets up the `devhost` group and `/run/lock/devhost` for [host-wide locks](#host-wide-locks), and adds you to the `docker` and `devhost` groups.

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
- **Locks:** a lock file your project takes on your laptop doesn't stop other laptops. See [Host-wide locks](#host-wide-locks).

## Host-wide locks

Projects often serialize heavy work with a lock on "the host": one E2E gate at a time, one image rebuild at a time, a single cache writer. Those locks are usually files under `/tmp` on the machine running the script. With devhost the work runs on the VM but the lock stays on each laptop, so two laptops both take "the" lock and run at once on the same VM.

`client/devhost lock` takes the lock on the VM instead:

```bash
client/devhost lock e2e -- task test:e2e                 # waits if someone else holds 'e2e'
client/devhost lock e2e --no-wait -- task test:e2e       # exits 75 right away if it's held
client/devhost lock e2e --timeout 600 -- task test:e2e   # waits at most 10 minutes, then exits 75
client/devhost lock --list                               # who holds what
```

```
NAME                 USER         HOST                     SINCE
e2e                  alice        alice-mbp                2026-10-29T14:02:11Z
```

The command runs on your laptop as usual, and `devhost lock` exits with its exit code. Ctrl-C reaches the command as usual, `TERM` and `HUP` sent to `devhost lock` are passed on to it, and in every case the lock is held until the command exits, including under `timeout` or a CI job being cancelled. An `INT` sent to the `devhost` process alone (not from the terminal) is ignored; use `TERM` to stop it from a script. While it runs, an SSH session to the VM holds `flock` on `/run/lock/devhost/<name>.lock`, and the lock goes away with that session. There are no stale locks to clean up: the VM releases the lock when the command finishes, when the script is killed (even with `kill -9`), or within about 40 seconds when the laptop sleeps or loses the network.

- If the connection drops while the command runs, the lock is released but the command keeps going; `devhost lock` prints a warning as soon as that happens.
- Exit code 75 means the lock wasn't taken, unless your command also exits 75. The "is held by" or "timed out" message on stderr tells the two apart.
- Put `client/devhost` on your `PATH` (e.g. `ln -s "$PWD/client/devhost" ~/.local/bin/devhost`) so project scripts can call `devhost`.
- The VM is found through the `devhost` Docker context. Set `DEVHOST_CONTEXT` to use another context, or `DEVHOST_SSH=user@host` to skip Docker.
- Only members of the VM's `devhost` group can take or list locks; `add-dev-user.sh` adds developers to it. If your VM was set up before this existed, re-run `install-docker.sh`, then `add-dev-user.sh` for each developer.
- Locks are host-wide across all users: the VM's CPU, memory and ports are shared no matter whose daemon or containers use them.
- On Windows, run the helper from WSL or Git Bash.

### Key locks on the daemon, not the machine

In project scripts, choose the lock by **where the Docker daemon runs**, not where the script runs. If the daemon is reached over SSH, lock on that host; otherwise keep the local lock:

```bash
# Run the rest of this script under the 'e2e' lock, on whichever machine runs the daemon.
if [ -z "${E2E_LOCKED:-}" ]; then
    export E2E_LOCKED=1
    daemon="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}"
    case "$daemon" in
        ssh://*) DEVHOST_SSH="$daemon" exec devhost lock e2e -- "$0" "$@" ;;   # remote daemon: lock on its host
    esac
    exec 9>/tmp/e2e.lock && flock 9                     # local daemon: lock on this machine
fi
```

Comparing `docker info --format '{{.Name}}'` with `hostname` also detects a remote daemon, but Docker Desktop's daemon reports `docker-desktop`, so it looks remote too. Scripts that can't use the helper can take the same lock with `ssh <host> flock /run/lock/devhost/<name>.lock <cmd>`, which runs `<cmd>` on the VM.

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
