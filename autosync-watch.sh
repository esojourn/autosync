#!/bin/bash
# Two-way folder sync via Unison over Tailscale (SSH)
# Watches for local changes with inotifywait, syncs periodically for remote changes.

# ── Sync targets: user@host → space-separated folder list ──
# Each entry can be "local_path" or "local_path:remote_path".
# When remote_path is omitted, it is auto-derived by replacing $HOME with /home/$USER.
declare -A SYNC_TARGETS
SYNC_TARGETS["sonic@DXOffice2021"]="$HOME/dev/autosync $HOME/dev/ChatGPT-Next-Web2 $HOME/dev/sk-add-ip"
SYNC_TARGETS["eso@tufub"]="$HOME/dev/autosync:/home/eso/dev/autosync $HOME/dev/newapi-log:/home/eso/dev/newapi-log"

# ── Global exclude patterns (applied to all folders) ──
GLOBAL_EXCLUDES=(
    .git node_modules .next __pycache__ .venv venv
    .env .cache .tox "*.pyc" .DS_Store .yarn
)

# ── Per-folder exclude patterns (in addition to globals) ──
# Use the folder path as key (must match entries in SYNC_TARGETS after expansion).
# Separate patterns with spaces.
declare -A FOLDER_EXCLUDES
FOLDER_EXCLUDES["$HOME/dev/autosync"]=""
FOLDER_EXCLUDES["$HOME/dev/ChatGPT-Next-Web2"]=".env.local"
FOLDER_EXCLUDES["$HOME/dev/sk-add-ip"]=""

# ── Settings ──
POLL_INTERVAL=60          # seconds between full syncs (catches remote-side changes)
DEBOUNCE=3                # seconds to wait after last local change before syncing
LOG_FILE="$HOME/.local/share/autosync/autosync.log"
STATUS_FILE="$HOME/.local/share/autosync/status"
STATE_FILE="$HOME/.local/share/autosync/state"
DISABLED_FILE="$HOME/.local/share/autosync/disabled"

mkdir -p "$(dirname "$LOG_FILE")"

# ── Parse user@host target ──
parse_target() {
    TARGET_USER="${1%%@*}"
    TARGET_HOST="${1#*@}"
}

# ── Parse "local:remote" or just "local" path spec ──
parse_path_spec() {
    local spec="$1"
    if [[ "$spec" == *:* ]]; then
        LOCAL_PATH="${spec%%:*}"
        REMOTE_PATH="${spec#*:}"
    else
        LOCAL_PATH="$spec"
        REMOTE_PATH=""
    fi
}

# ── Build deduplicated local folder list across all hosts ──
declare -A _seen_folders
ALL_FOLDERS=()
for _target in "${!SYNC_TARGETS[@]}"; do
    for _spec in ${SYNC_TARGETS[$_target]}; do
        parse_path_spec "$_spec"
        if [ -z "${_seen_folders[$LOCAL_PATH]}" ]; then
            _seen_folders[$LOCAL_PATH]=1
            ALL_FOLDERS+=("$LOCAL_PATH")
        fi
    done
done
unset _seen_folders _target _spec

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

set_state() {
    echo "$1|$(date '+%Y-%m-%d %H:%M:%S')" > "$STATE_FILE"
}

update_status() {
    local host="$1" folder="$2" status="$3" trigger="$4"
    local ts key
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    key="${host}|${folder}"
    if [ -f "$STATUS_FILE" ] && grep -q "^${key}|" "$STATUS_FILE"; then
        sed -i "s#^${key}|.*#${key}|${status}|${ts}|${trigger}#" "$STATUS_FILE"
    else
        echo "${key}|${status}|${ts}|${trigger}" >> "$STATUS_FILE"
    fi
}

is_host_disabled() {
    [ -f "$DISABLED_FILE" ] && grep -qxF "$1" "$DISABLED_FILE"
}

is_folder_disabled() {
    [ -f "$DISABLED_FILE" ] && grep -qxF "$1|$2" "$DISABLED_FILE"
}

# ── Sync all folders to all hosts ──
sync_all() {
    local trigger="${1:-periodic}"
    set_state "syncing"
    for target in "${!SYNC_TARGETS[@]}"; do
        parse_target "$target"
        # Skip disabled hosts
        if is_host_disabled "$target"; then
            log "Host $TARGET_HOST paused, skipping"
            continue
        fi
        # Check host reachability before syncing its folders
        if ! ssh -o ConnectTimeout=5 "$target" "true" 2>/dev/null; then
            log "Host $TARGET_HOST unreachable, skipping"
            for _spec in ${SYNC_TARGETS[$target]}; do
                parse_path_spec "$_spec"
                update_status "$target" "$LOCAL_PATH" "FAILED" "$trigger"
            done
            continue
        fi
        for spec in ${SYNC_TARGETS[$target]}; do
            parse_path_spec "$spec"
            local folder="$LOCAL_PATH"
            # Skip disabled folders
            if is_folder_disabled "$target" "$folder"; then
                log "Folder $folder on $TARGET_HOST paused, skipping"
                continue
            fi
            local remote_path
            if [ -n "$REMOTE_PATH" ]; then
                remote_path="$REMOTE_PATH"
            else
                remote_path="${folder/#$HOME/\/home\/$TARGET_USER}"
            fi
            ssh -o ConnectTimeout=10 "$target" "mkdir -p '$remote_path'" 2>/dev/null
            log "Syncing $folder ↔ $TARGET_HOST:$remote_path"
            # Build ignore args from global + per-folder excludes
            local ignore_args=()
            for pattern in "${GLOBAL_EXCLUDES[@]}"; do
                ignore_args+=(-ignore "Name $pattern")
            done
            local excludes="${FOLDER_EXCLUDES[$folder]}"
            for pattern in $excludes; do
                ignore_args+=(-ignore "Name $pattern")
            done

            unison "$folder" "ssh://$target/$remote_path" \
                -auto -batch \
                -prefer newer \
                -times \
                -retry 3 \
                -sshargs "-o ConnectTimeout=10" \
                "${ignore_args[@]}" \
                -logfile "$LOG_FILE" \
                2>&1 | tee -a "$LOG_FILE"
            if [ ${PIPESTATUS[0]} -eq 0 ]; then
                log "Sync OK: $folder -> $TARGET_HOST"
                update_status "$target" "$folder" "OK" "$trigger"
            else
                log "Sync FAILED: $folder -> $TARGET_HOST"
                update_status "$target" "$folder" "FAILED" "$trigger"
            fi
        done
    done
    set_state "watching"
}

# ── Initial sync ──
log "=== autosync started ==="
> "$STATUS_FILE"
sync_all "startup"

# ── Watch for local changes + periodic sync for remote changes ──
LAST_SYNC=$(date +%s)

# Build inotifywait watch paths
WATCH_PATHS=()
for folder in "${ALL_FOLDERS[@]}"; do
    WATCH_PATHS+=("$folder")
done

# Build inotifywait exclude regex from global + per-folder excludes
# Convert glob patterns (used by unison) to regex for inotifywait
_glob_to_regex() {
    local p="$1"
    # Escape regex-special chars, then convert glob * to .*
    p="${p//\./\\.}"
    p="${p//\*/.*}"
    p="${p//\?/.}"
    echo "$p"
}
declare -A _seen_patterns
INOTIFY_EXCLUDE=""
for pattern in "${GLOBAL_EXCLUDES[@]}" ; do
    _seen_patterns[$pattern]=1
    local_re=$(_glob_to_regex "$pattern")
    if [ -z "$INOTIFY_EXCLUDE" ]; then
        INOTIFY_EXCLUDE="/(${local_re}"
    else
        INOTIFY_EXCLUDE="${INOTIFY_EXCLUDE}|${local_re}"
    fi
done
for folder in "${ALL_FOLDERS[@]}"; do
    for pattern in ${FOLDER_EXCLUDES[$folder]}; do
        [ -n "${_seen_patterns[$pattern]}" ] && continue
        _seen_patterns[$pattern]=1
        local_re=$(_glob_to_regex "$pattern")
        INOTIFY_EXCLUDE="${INOTIFY_EXCLUDE}|${local_re}"
    done
done
[ -n "$INOTIFY_EXCLUDE" ] && INOTIFY_EXCLUDE="${INOTIFY_EXCLUDE})/"
unset _seen_patterns

log "Watching ${WATCH_PATHS[*]} for changes (poll every ${POLL_INTERVAL}s)"
[ -n "$INOTIFY_EXCLUDE" ] && log "Excluding pattern: $INOTIFY_EXCLUDE"

MANUAL_SYNC=0
trap 'MANUAL_SYNC=1' USR1

while true; do
    # Wait for local file change OR timeout for periodic sync
    inotifywait -r -q -t "$POLL_INTERVAL" \
        -e modify,create,delete,move \
        ${INOTIFY_EXCLUDE:+--exclude "$INOTIFY_EXCLUDE"} \
        "${WATCH_PATHS[@]}" >/dev/null 2>&1
    EXIT_CODE=$?

    NOW=$(date +%s)

    if [ $MANUAL_SYNC -eq 1 ]; then
        MANUAL_SYNC=0
        log "Manual sync triggered"
        sync_all "manual"
        LAST_SYNC=$NOW
    elif [ $EXIT_CODE -eq 0 ]; then
        # Local change detected — debounce
        log "Change detected, waiting ${DEBOUNCE}s to debounce..."
        sleep "$DEBOUNCE"
        # Drain any queued events
        while inotifywait -r -q -t 1 -e modify,create,delete,move ${INOTIFY_EXCLUDE:+--exclude "$INOTIFY_EXCLUDE"} "${WATCH_PATHS[@]}" >/dev/null 2>&1; do
            sleep 1
        done
        sync_all "change"
        LAST_SYNC=$NOW
    elif [ $EXIT_CODE -eq 2 ]; then
        # Timeout — periodic sync to catch remote changes
        log "Periodic sync..."
        sync_all "periodic"
        LAST_SYNC=$NOW
    fi
done
