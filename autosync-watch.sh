#!/bin/bash
# Two-way folder sync via Unison over Tailscale (SSH)
# Watches for local changes with inotifywait, syncs periodically for remote changes.

REMOTE_USER="sonic"
REMOTE_HOST="DXOffice2021"

# ── Folders to sync (add more entries as needed) ──
SYNC_FOLDERS=(
    "$HOME/dev/autosync"
    "$HOME/dev/ChatGPT-Next-Web2"
)

# ── Per-folder exclude patterns ──
# Use the folder path as key (must match SYNC_FOLDERS entries after expansion).
# Separate patterns with spaces.
declare -A FOLDER_EXCLUDES
FOLDER_EXCLUDES["$HOME/dev/autosync"]=""
FOLDER_EXCLUDES["$HOME/dev/ChatGPT-Next-Web2"]=".next node_modules .git .yarn .env.local"

# ── Settings ──
POLL_INTERVAL=60          # seconds between full syncs (catches remote-side changes)
DEBOUNCE=3                # seconds to wait after last local change before syncing
LOG_FILE="$HOME/.local/share/autosync/autosync.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ── Build unison args for each folder ──
sync_all() {
    for folder in "${SYNC_FOLDERS[@]}"; do
        local remote_path="${folder/#$HOME/\/home\/$REMOTE_USER}"
        log "Syncing $folder ↔ $REMOTE_HOST:$remote_path"
        # Build ignore args from per-folder excludes
        local ignore_args=()
        local excludes="${FOLDER_EXCLUDES[$folder]}"
        for pattern in $excludes; do
            ignore_args+=(-ignore "Name $pattern")
        done

        unison "$folder" "ssh://$REMOTE_USER@$REMOTE_HOST/$remote_path" \
            -auto -batch \
            -prefer newer \
            -times \
            -retry 3 \
            -sshargs "-o ConnectTimeout=10" \
            "${ignore_args[@]}" \
            -logfile "$LOG_FILE" \
            2>&1 | tee -a "$LOG_FILE"
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            log "Sync OK: $folder"
        else
            log "Sync FAILED: $folder"
        fi
    done
}

# ── Initial sync ──
log "=== autosync started ==="
sync_all

# ── Watch for local changes + periodic sync for remote changes ──
LAST_SYNC=$(date +%s)

# Build inotifywait watch paths
WATCH_PATHS=()
for folder in "${SYNC_FOLDERS[@]}"; do
    WATCH_PATHS+=("$folder")
done

# Build inotifywait exclude regex from all per-folder excludes
declare -A _seen_patterns
INOTIFY_EXCLUDE=""
for folder in "${SYNC_FOLDERS[@]}"; do
    for pattern in ${FOLDER_EXCLUDES[$folder]}; do
        [ -n "${_seen_patterns[$pattern]}" ] && continue
        _seen_patterns[$pattern]=1
        if [ -z "$INOTIFY_EXCLUDE" ]; then
            INOTIFY_EXCLUDE="/(${pattern}"
        else
            INOTIFY_EXCLUDE="${INOTIFY_EXCLUDE}|${pattern}"
        fi
    done
done
[ -n "$INOTIFY_EXCLUDE" ] && INOTIFY_EXCLUDE="${INOTIFY_EXCLUDE})/"
unset _seen_patterns

log "Watching ${WATCH_PATHS[*]} for changes (poll every ${POLL_INTERVAL}s)"
[ -n "$INOTIFY_EXCLUDE" ] && log "Excluding pattern: $INOTIFY_EXCLUDE"

while true; do
    # Wait for local file change OR timeout for periodic sync
    inotifywait -r -q -t "$POLL_INTERVAL" \
        -e modify,create,delete,move \
        ${INOTIFY_EXCLUDE:+--exclude "$INOTIFY_EXCLUDE"} \
        "${WATCH_PATHS[@]}" >/dev/null 2>&1
    EXIT_CODE=$?

    NOW=$(date +%s)

    if [ $EXIT_CODE -eq 0 ]; then
        # Local change detected — debounce
        log "Change detected, waiting ${DEBOUNCE}s to debounce..."
        sleep "$DEBOUNCE"
        # Drain any queued events
        while inotifywait -r -q -t 1 -e modify,create,delete,move ${INOTIFY_EXCLUDE:+--exclude "$INOTIFY_EXCLUDE"} "${WATCH_PATHS[@]}" >/dev/null 2>&1; do
            sleep 1
        done
        sync_all
        LAST_SYNC=$NOW
    elif [ $EXIT_CODE -eq 2 ]; then
        # Timeout — periodic sync to catch remote changes
        log "Periodic sync..."
        sync_all
        LAST_SYNC=$NOW
    fi
done
