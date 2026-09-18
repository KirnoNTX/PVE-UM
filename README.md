# Proxmox Virtual Environment Update Manager

PVE UM is a Bash script to update a Proxmox host and/or its Debian/Ubuntu LXC containers, with both an interactive menu and non-interactive flags for automation (cron, scripts, etc.).

## Features

- Updates the Proxmox host itself (`apt-get update && full-upgrade`).
- Auto-discovers running LXC containers via `pct list`.
- Skips containers that are stopped or running an unsupported distro (only Debian/Ubuntu are handled).
- Interactive checklist selection (`whiptail`/`dialog` if available, plain numbered prompt otherwise).
- Non-interactive flags for automation.
- Logs everything to a timestamped file under `/var/log/`.
- Prints a summary of updated / failed / skipped targets at the end.

## Requirements

- Must be run as **root** (or via `sudo`).
- Chmod +x the file
- Must be run **on the Proxmox node itself** (requires the `pct` command).
- Optional: `whiptail` or `dialog` for a nicer interactive checklist (falls back to a plain text prompt if neither is installed).

## Usage

### Interactive mode

```bash
sudo ./update-manager.sh
```

This shows a menu:

```sh
1) Update everything (host + all containers)
2) Proxmox host only
3) Containers only (all)
4) Manual selection (host and/or containers of choice)
0) Cancel
```

Option 4 opens a checklist (or numbered prompt) letting you pick exactly which container(s) and/or the host to update.

### Non-interactive mode

Useful for cron jobs or remote automation:

```bash
sudo ./update-manager.sh --all                # host + all running containers
sudo ./update-manager.sh --host-only          # host only
sudo ./update-manager.sh --cts-only           # all running containers, host untouched
sudo ./update-manager.sh --only host,101,105  # host + specific container IDs
```

`--only` takes a comma-separated list combining `host` and/or container VMIDs.

## How it works

1. **Discovery** (`discover_containers`): lists running containers with `pct list`, checks each one's `/etc/os-release` via `pct exec`, and keeps only Debian/Ubuntu ones. Anything stopped or on another distro is recorded as skipped.
2. **Update** (`update_host` / `update_container`): runs the same apt sequence everywhere:

   ```sh
   apt-get update
   apt-get full-upgrade -y   (with confdef/confold to avoid interactive prompts)
   apt list --upgradable
   apt-get autoremove -y && apt-get autoclean
   ```

   `DEBIAN_FRONTEND=noninteractive` and `NEEDRESTART_MODE=a` keep the whole run unattended.
3. **Logging**: every target's full output is appended to `/var/log/update-manager-<timestamp>.log`; only the last 20 lines are shown on screen if something fails.
4. **Summary**: at the end, prints how many targets were updated, failed, or skipped, plus the path to the full log.

## Notes / caveats

- The script does **not** reboot containers or the host, even if a kernel/library update would normally require it — check `needrestart`/pending reboots manually afterward if needed.
- Only containers currently **running** are considered; stopped containers are skipped (not started automatically).
- Only **Debian/Ubuntu** containers are supported; others (Alpine, CentOS, etc.) are skipped.
- Exit code is always `0` on the non-interactive flags, even if some targets failed — check the summary/log for actual results.
