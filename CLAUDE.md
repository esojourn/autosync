# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Autosync is a two-way folder sync tool using Unison over Tailscale SSH. It runs as a systemd user service, watches local folders with `inotifywait`, and polls periodically for remote changes. A TUI script provides live monitoring and interactive service management.

## Architecture

Two bash scripts, no build step:

- **`autosync-watch.sh`** — The sync daemon. Runs continuously as a systemd service. On startup it does an initial sync of all folders, then enters a loop: `inotifywait` blocks until a local file change or timeout (60s). Local changes trigger a debounced sync; timeouts trigger a periodic sync. Each sync calls `unison` per folder with `-auto -batch -prefer newer`. Writes machine-readable status to `~/.local/share/autosync/status` (pipe-delimited: `FOLDER|STATUS|TIMESTAMP|TRIGGER`) and current state to `~/.local/share/autosync/state`.

- **`autosync-tui.sh`** — TUI monitor and service manager. Two modes: **dashboard** (default) shows sync status + recent activity with keybindings for service management (install/uninstall/start/stop/restart); **log viewer** (`l` key) shows full scrollable log with arrow key navigation. Dangerous actions (stop, uninstall) require `y/N` confirmation. Redraws every 2s.

## Runtime Files

All under `~/.local/share/autosync/`:
- `autosync.log` — Timestamped log (script messages + raw unison output interleaved)
- `status` — Per-folder sync status (pipe-delimited)
- `state` — Current daemon state (`watching` or `syncing` with timestamp)

## Service Management

Preferred: use the TUI (`./autosync-tui.sh`) which provides interactive install/uninstall/start/stop/restart. Or via CLI:

```bash
systemctl --user status autosync
systemctl --user restart autosync    # after editing autosync-watch.sh
systemctl --user stop autosync
```

Service file: `~/.config/systemd/user/autosync.service`. The TUI's install command generates this file automatically from the script's location.

## Configuration

All config is at the top of `autosync-watch.sh`: `REMOTE_USER`, `REMOTE_HOST`, `SYNC_FOLDERS` array, `GLOBAL_EXCLUDES` array, `FOLDER_EXCLUDES` associative array, `POLL_INTERVAL`, `DEBOUNCE`. After changes, restart the service.

## Dependencies

- `unison` (both local and remote)
- `inotify-tools` (local only, provides `inotifywait`)
- Tailscale with SSH key auth to the remote host
