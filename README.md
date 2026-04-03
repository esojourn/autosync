# autosync

Two-way folder sync between local machine and a remote Tailscale host using [Unison](https://www.cis.upenn.edu/~bcpierce/unison/) over SSH. Watches for local file changes in real time and polls periodically to catch remote changes.

## How it works

- Local file changes are detected instantly via `inotifywait`
- A 3-second debounce prevents rapid-fire syncs during bulk edits
- Every 60 seconds, a full sync runs to pick up remote-side changes
- When the same file is modified on both sides, the **newer version wins**
- Excluded patterns (e.g. `node_modules`, `.git`) are skipped in both sync and file watching

## Requirements

**Local machine:**

```bash
sudo apt install unison inotify-tools
```

**Remote machines** must have `unison` installed and SSH access configured. See [Remote Host Setup](#remote-host-setup) below.

## Remote Host Setup

### Linux

```bash
# 1. Install unison
sudo apt install unison

# 2. Ensure Tailscale is installed and connected
# https://tailscale.com/download/linux

# 3. Set up SSH key auth (run on LOCAL machine)
ssh-copy-id user@remote-host

# 4. Test connection
ssh user@remote-host "unison -version"
```

### WSL (Windows host with Tailscale on Windows)

Routes SSH through Windows Tailscale into WSL, keeping a single tailnet node.

**In WSL**, install unison:

```bash
sudo apt install unison
```

**On Windows** (PowerShell as Admin):

1. **Enable OpenSSH Server:**
   ```powershell
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Start-Service sshd
   Set-Service -Name sshd -StartupType Automatic
   ```

2. **Set WSL as default shell for your user** — edit `C:\ProgramData\ssh\sshd_config`:
   ```
   Match User eso
       ForceCommand C:\Windows\System32\wsl.exe -e bash -login
   ```
   Then restart sshd:
   ```powershell
   Restart-Service sshd
   ```

3. **Set up SSH key auth** (run on LOCAL machine):
   ```bash
   ssh-copy-id user@remote-host
   ```

4. **Test connection** (run on LOCAL machine):
   ```bash
   ssh user@remote-host "unison -version"
   ```

> **Note:** Paths in `SYNC_TARGETS` use the WSL filesystem (e.g. `~/dev/autosync` maps to `/home/user/dev/autosync` inside WSL), not Windows paths.

## Configuration

Edit the top of `autosync-watch.sh`:

```bash
# Sync targets: user@host -> space-separated folder list
declare -A SYNC_TARGETS
SYNC_TARGETS["sonic@DXOffice2021"]="$HOME/dev/autosync $HOME/dev/ChatGPT-Next-Web2"
SYNC_TARGETS["eso@tuf"]="$HOME/dev/autosync"

# Global exclude patterns (applied to all folders)
GLOBAL_EXCLUDES=(
    .git node_modules .next __pycache__ .venv venv
    .env .cache .tox "*.pyc" .DS_Store .yarn
)

# Per-folder exclude patterns (in addition to globals)
declare -A FOLDER_EXCLUDES
FOLDER_EXCLUDES["$HOME/dev/ChatGPT-Next-Web2"]=".env.local"
```

Each remote host has its own independently defined set of sync folders. Remote paths mirror local paths under the remote user's home directory.

After editing, restart the service:

```bash
systemctl --user restart autosync
```

## TUI Monitor

Run the terminal UI to monitor and manage autosync:

```bash
./autosync-tui.sh
```

### Dashboard (default view)

- Service status: Running / Stopped / Not Installed
- Per-folder last sync time, result (OK/FAIL), and trigger type
- Color-coded recent activity log

**Key bindings (adapt to current service state):**

| Key | Action |
|-----|--------|
| `i` | Install service (only when not installed) |
| `u` | Uninstall service (with confirmation) |
| `s` | Start or Stop service (stop requires confirmation) |
| `r` | Restart service |
| `l` | Open log viewer |
| `q` | Quit |

### Log viewer

Full-screen scrollable view of the complete log file.

| Key | Action |
|-----|--------|
| `↑` / `↓` | Scroll up/down |
| `g` / `G` | Jump to top/bottom |
| `Esc` | Back to dashboard |

## Service management (CLI)

The TUI handles service management interactively. You can also use systemctl directly:

```bash
systemctl --user status autosync
systemctl --user start autosync
systemctl --user stop autosync
systemctl --user restart autosync
```

## Logs

```bash
# Live log in terminal
tail -f ~/.local/share/autosync/autosync.log

# TUI log viewer (recommended)
./autosync-tui.sh   # then press l
```

## Files

| File | Location |
|------|----------|
| Sync script | `~/dev/autosync/autosync-watch.sh` |
| TUI monitor | `~/dev/autosync/autosync-tui.sh` |
| Systemd service | `~/.config/systemd/user/autosync.service` |
| Log file | `~/.local/share/autosync/autosync.log` |
| Status file | `~/.local/share/autosync/status` |
| State file | `~/.local/share/autosync/state` |
