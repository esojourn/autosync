# autosync

Two-way folder sync between local machine and a remote Tailscale host using [Unison](https://www.cis.upenn.edu/~bcpierce/unison/) over SSH. Watches for local file changes in real time and polls periodically to catch remote changes.

## How it works

- Local file changes are detected instantly via `inotifywait`
- A 3-second debounce prevents rapid-fire syncs during bulk edits
- Every 60 seconds, a full sync runs to pick up remote-side changes
- When the same file is modified on both sides, the **newer version wins**
- Excluded patterns (e.g. `node_modules`, `.git`) are skipped in both sync and file watching

## Requirements

Install on **both** local and remote machines:

```bash
sudo apt install unison
```

Local machine also needs:

```bash
sudo apt install inotify-tools
```

SSH key auth must be configured between local and remote.

## Configuration

Edit the top of `autosync-watch.sh`:

```bash
# Remote host
REMOTE_USER="sonic"
REMOTE_HOST="DXOffice2021"

# Folders to sync (local paths — remote paths mirror these under the remote user's home)
SYNC_FOLDERS=(
    "$HOME/dev/autosync"
    "$HOME/dev/ChatGPT-Next-Web2"
)

# Global exclude patterns (applied to all folders)
GLOBAL_EXCLUDES=(
    .git node_modules .next __pycache__ .venv venv
    .env .cache .tox "*.pyc" .DS_Store .yarn
)

# Per-folder exclude patterns (in addition to globals)
declare -A FOLDER_EXCLUDES
FOLDER_EXCLUDES["$HOME/dev/ChatGPT-Next-Web2"]=".env.local"
```

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
