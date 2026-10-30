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
| `guest/allow-path.sh` | VM | Creates a developer's laptop path prefix on the VM, for `client/devhost` syncing |
| `client/add-devhost-context.sh` | macOS / Linux laptop | Creates the `devhost` Docker context and offers an `~/.ssh/config` block |
| `client/Add-DevHostContext.ps1` | Windows laptop | Same, for Windows |
| `client/devhost` | macOS / Linux laptop | Runs projects unmodified: mirrors published ports onto `127.0.0.1` and syncs the checkout to the VM |
| `tests/` | anywhere | `make check` runs shellcheck and the `client/devhost` tests (fake `docker`/`ssh`/`mutagen`) |

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

The script also offers to add a block for the host to `~/.ssh/config` (`ControlMaster auto`, `ControlPersist 10m`, `ConnectTimeout 3`, `ServerAliveInterval 15`). Take it: every `docker` call then reuses one SSH connection, which is much faster, and a shell doesn't hang for a minute when the VM is saved.

## Using the shared host

- **Ports:** `docker run -p 8080:80 …` is reachable at `http://devhost:8080`. A port bound to loopback (`-p 127.0.0.1:6379:6379`) listens on the *VM's* loopback and is not reachable from your laptop unless you use `client/devhost` (below).
- **Bind mounts refer to the VM's filesystem, not your laptop.** `-v ./src:/app` mounts a folder on the VM. Either bake code into images, use named volumes, or run the command through `client/devhost`, which syncs the checkout to the same path on the VM. `docker build` works normally; the build context is uploaded from your laptop.
- **Firewall:** ports published by Docker bypass `ufw`, because Docker manages iptables directly. Keep the VM on a trusted network.
- **Cleanup:** images and build cache add up on a shared host. Run `docker system prune` periodically.
- **One daemon, many developers.** Compose project names come from the directory name, and container, volume, network and kind cluster names are global to the daemon. Two developers with a checkout of the same name share (and clobber) each other's stack: set `COMPOSE_PROJECT_NAME` or `name:` per developer. Fixed host ports (`127.0.0.1:6379` on the VM) also collide between developers, so agree on port ranges or prefer ephemeral ports. Locks a project keeps on the laptop ("one E2E run per host") don't stop other laptops using the same daemon.
- **While the VM is off or saved** every `docker` call hangs on SSH until it times out. Use `client/devhost probe` in scripts and hooks to opt in only when it's reachable.

## 6. Run projects unmodified: `client/devhost`

Most dev workflows assume the daemon is local in two ways: they dial published ports on `127.0.0.1`, and they bind-mount files from the checkout. `client/devhost` (bash, macOS and Linux) makes both work against devhost without changing the project:

```bash
devhost run -- task test:int      # forwards + sync around one command
devhost up                        # start forwarder + sync for $PWD, stay running
devhost flush                     # during `up`: push local changes / pull outputs now
devhost down                      # stop them
devhost status                    # reachable? forwards? sync state?
devhost probe                     # exit 0 if the daemon answers, 1 within 5s if not
```

`devhost run` sets `DOCKER_CONTEXT=devhost` for the child process only; your default context stays whatever it was. It passes the child's exit code through, and still brings outputs back when the command fails. If a port published while the command ran could not be mirrored (see conflicts below), `run` exits 1 even when the command succeeded. Ctrl-C reaches the command as usual; a `TERM` or `HUP` sent to `devhost run` (`timeout`, a CI cancel, a closed terminal) is passed on to the command, and the teardown then completes even if more signals arrive.

Several `devhost run`s in the same checkout (parallel test shards, two terminals, an agent) share one session; the last one to finish tears it down. Inside a `devhost up` session, `run` only flushes the sync before and after the command and leaves the session up. `devhost up` while a `run` is active keeps the session after that run ends, and `devhost down` always stops it. State lives in `~/.devhost`.

**Requirements on the laptop:** OpenSSH, the Docker CLI with the `devhost` context, and [Mutagen](https://mutagen.io) (`brew install mutagen-io/mutagen/mutagen`, or the release binary; it installs its own agent on the VM over SSH). Put `client/devhost` on your `PATH`, or symlink it. Set `DEVHOST_NO_SYNC=1` to mirror ports without syncing files (no Mutagen needed).

**Setup on the VM, once per developer:** the sync puts your checkout at the *same absolute path* on the VM, so that path prefix has to exist there and belong to you:

```bash
sudo ./guest/allow-path.sh alice /Users/alice      # macOS laptop
sudo ./guest/allow-path.sh bob   /home/bob         # Linux laptop
```

The script refuses if any component is owned by another developer: two laptops whose checkouts map to the same VM path must not share it. Pick a different checkout location instead.

### Ports

`devhost up` (and `run`) opens one SSH connection to the VM and, for every port the daemon publishes, adds a forward from `127.0.0.1:<port>` on the laptop to the same port on the VM. Forwards are added when containers start and removed when they die (`docker events`), so ephemeral ports (`-p 127.0.0.1::3000`, `docker compose port`) come out at the same number and project code dials them unchanged. Ports bound to `0.0.0.0` on the VM are mirrored too. UDP is not forwarded.

- The laptop side binds to `127.0.0.1` only. Nothing becomes reachable from your LAN that wasn't before, and ports bound to loopback on the VM stay unreachable from the LAN.
- **Conflicts:** if the laptop port is already taken (a local redis, Docker Desktop holding 6379), the helper reports the container, the port and what holds it, and does **not** forward it to a different port, because the project would then talk to the wrong service. `run` exits 1 if a conflict appears for a container that started while the command ran (the project's own services). A conflict on a container that was already running before the command (on a shared daemon, usually somebody else's) is printed as a warning and the run continues; set `DEVHOST_CONFLICTS=fail` to refuse in that case too, or `DEVHOST_CONFLICTS=warn` to never fail on conflicts. During `up`, a conflict is printed to the terminal `up` was started from as it happens, `devhost status` leads with it, and `devhost flush` reports it and exits 1 (unless `warn`), so scripts notice. A conflict is forgotten when its container stops, and `run`/`flush` ask the forwarder to retry recorded conflicts first, so freeing the port and retrying works.
- **Lost connection:** the forwarder runs its `docker events` stream and queries through the same SSH connection as the forwards (with keepalives), so a connection that drops ends the stream. It then retries with backoff until the daemon answers and reconciles: forwards for containers that are gone are removed and new ones added. If the SSH connection itself died (laptop sleep, VM reboot, network change), its forwards died with it; the forwarder notices the new connection and opens them again, as does the next `devhost run`. If a previous forwarder died uncleanly, the next `up` cancels what it left behind.
- A port published on a specific VM interface (`-p 192.168.1.5:8080:80`) is mirrored to that address on the VM. IPv4 loopback and wildcard bindings go to the VM's `127.0.0.1`; an IPv6-only binding (`[::1]:8080`, or `[::]` without `0.0.0.0`) goes to the VM's `::1`.
- **Scope:** the first version forwards *every* port the daemon publishes, including other developers' containers on a shared host, which then conflict on your laptop (reported, but not fatal to `run` by default, see above). Limiting forwards to your own containers needs an ownership convention and is a follow-up.

### Files

`devhost up` creates a Mutagen session from `$PWD` to `user@devhost:$PWD` in `two-way-resolved` mode, with the laptop winning conflicts. Whatever containers write into the checkout (test diffs, regenerated goldens, `-v "$PWD/out:/out"`) comes back. `run` flushes the sync before the command and again after it, so outputs are on the laptop by the time it returns; during `up`, call `devhost flush` from scripts that need the same guarantee mid-session.

- **Between sessions the VM copy stays, but it is made to match the laptop before each new session.** A new two-way session has no history, so files that exist only on the VM (deleted or renamed locally since the last run, another branch's files after a `git checkout`, old outputs) would otherwise count as new and be copied back into the checkout. The helper first runs a one-way replica from the laptop, waits for it, and only then starts the two-way session. Files matching the ignore list are never touched on either side. The initial sync of a new session gets `DEVHOST_SYNC_TIMEOUT` (default 600s); later flushes get `DEVHOST_FLUSH_TIMEOUT` (default 60s).
- **A flush that fails or times out is fatal before a command runs** (`run` exits 1 without running it, `devhost flush` exits 1), so scripts never run against a half-synced checkout. The flush after the command only warns, because the command's own exit code matters more; `devhost flush` again if outputs look stale.
- **One session per tree:** `devhost run` in a subdirectory of a checkout that is already up is refused (the parent session already covers it: run from there), as is a session over a directory that already has one inside it. Paths are resolved through symlinks first, so `/tmp/x` and `/private/tmp/x` on macOS are the same checkout.
- A `run` that crashed or was killed leaves its sync running until the next devhost command, which terminates it along with the stale session. When the last directory goes down, every devhost sync Mutagen still has is terminated; `devhost status` lists them under "other devhost syncs".

- **Ignores:** `node_modules`, `.git`, `.venv`, `target` and `dist` are not synced by default. A `.devhostignore` file in the checkout (one Mutagen pattern per line, `#` comments) replaces that list. Laptop-built `node_modules` are useless inside Linux containers anyway.
- **Root-owned files:** containers running as root write root-owned files on the VM, which Mutagen can't update or delete afterwards. `devhost run` prints a warning when the sync reports permission problems; fix it on the VM with `sudo chown -R $USER <path>`, or run the container with `--user "$(id -u)"`.

### Availability probe and agent hooks

`devhost probe` exits 0 when the daemon answers and 1 within 5 seconds when the VM is saved or off (it never reuses a shared SSH master, whose liveness can't be bounded). Shell rc files, direnv and agent hooks can opt in only when devhost is reachable. A Claude Code `SessionStart` hook, in `.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if devhost probe >/dev/null 2>&1; then echo 'export DEVHOST_AVAILABLE=1' >> \"$CLAUDE_ENV_FILE\"; fi"
          }
        ]
      }
    ]
  }
}
```

Scripts then check `DEVHOST_AVAILABLE` and wrap Docker-heavy commands in `devhost run -- …` (or write `export DOCKER_CONTEXT=devhost` instead if ports and mounts don't matter for the session).

### Known limitations

- **kind:** a cluster whose config uses `listenAddress: 127.0.0.1` publishes the API server and `hostPort`s from the node container, so they are mirrored like any other port and `kubectl` from the laptop should reach `127.0.0.1:<port>`. This has not been verified end-to-end; a free-port probe the project runs on the laptop still checks the laptop, not the VM.
- `devhost status` and the forwarder report the state of this laptop's forwards only; they don't know what other laptops forward.

### Developing the helper

```bash
make check     # shellcheck + tests (fake docker/ssh/mutagen/lsof in tests/fakes)
```

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
