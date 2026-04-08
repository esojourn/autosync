#!/bin/bash
# Terminal UI for autosync status monitoring and service management
# Reads status/state files written by autosync-watch.sh and tails the log.

STATUS_DIR="$HOME/.local/share/autosync"
STATUS_FILE="$STATUS_DIR/status"
STATE_FILE="$STATUS_DIR/state"
LOG_FILE="$STATUS_DIR/autosync.log"
DISABLED_FILE="$STATUS_DIR/disabled"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="$HOME/.config/systemd/user/autosync.service"

# Colors
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
WHITE="\033[37m"
BG_BLUE="\033[44m"
REVERSE="\033[7m"

# UI mode: dashboard, log, or filter
MODE="dashboard"
LOG_OFFSET=0       # scroll offset for log view (lines from bottom)
FILTER_CURSOR=0    # cursor position in filter view
CONFIRM_ACTION=""  # pending confirmation action
MESSAGE=""         # temporary status message
MESSAGE_TIME=0     # when the message was set

# Filter items: flat list of "host" or "host|folder" entries for cursor navigation
FILTER_ITEMS=()
FILTER_TYPES=()    # "host" or "folder" for each item

cleanup() {
    tput cnorm   # show cursor
    tput rmcup   # restore screen
    exit 0
}
trap cleanup EXIT INT TERM

tput smcup   # save screen
tput civis   # hide cursor

show_message() {
    MESSAGE="$1"
    MESSAGE_TIME=$(date +%s)
}

is_host_disabled() {
    [ -f "$DISABLED_FILE" ] && grep -qxF "$1" "$DISABLED_FILE"
}

is_folder_disabled() {
    [ -f "$DISABLED_FILE" ] && grep -qxF "$1|$2" "$DISABLED_FILE"
}

is_item_disabled() {
    local host="$1" folder="$2"
    if [ -n "$folder" ]; then
        is_host_disabled "$host" || is_folder_disabled "$host" "$folder"
    else
        is_host_disabled "$host"
    fi
}

toggle_host() {
    local host="$1"
    if is_host_disabled "$host"; then
        # Re-enable: remove host line and all its folder lines
        [ -f "$DISABLED_FILE" ] && grep -vxF "$host" "$DISABLED_FILE" | grep -v "^${host}|" > "$DISABLED_FILE.tmp"
        mv "$DISABLED_FILE.tmp" "$DISABLED_FILE"
        show_message "Enabled $host"
    else
        # Disable: add host line
        echo "$host" >> "$DISABLED_FILE"
        show_message "Paused $host"
    fi
}

toggle_folder() {
    local host="$1" folder="$2"
    local key="$host|$folder"
    # If entire host is disabled, can't toggle individual folders
    if is_host_disabled "$host"; then
        show_message "Enable the host first"
        return
    fi
    if is_folder_disabled "$host" "$folder"; then
        [ -f "$DISABLED_FILE" ] && grep -vxF "$key" "$DISABLED_FILE" > "$DISABLED_FILE.tmp"
        mv "$DISABLED_FILE.tmp" "$DISABLED_FILE"
        show_message "Enabled ${folder##*/}"
    else
        echo "$key" >> "$DISABLED_FILE"
        show_message "Paused ${folder##*/}"
    fi
}

build_filter_items() {
    FILTER_ITEMS=()
    FILTER_TYPES=()
    if [ ! -f "$STATUS_FILE" ]; then
        return
    fi
    local prev_host=""
    while IFS='|' read -r host folder _rest; do
        [ -z "$host" ] && continue
        if [ "$host" != "$prev_host" ]; then
            FILTER_ITEMS+=("$host")
            FILTER_TYPES+=("host")
            prev_host="$host"
        fi
        FILTER_ITEMS+=("$host|$folder")
        FILTER_TYPES+=("folder")
    done < "$STATUS_FILE"
}

draw_filter() {
    local cols rows
    cols=$(tput cols)
    rows=$(tput lines)
    tput cup 0 0

    build_filter_items

    # Header
    local service_status
    if ! is_service_installed; then
        service_status="${DIM}○ Not Installed${RESET}"
    elif is_service_running; then
        service_status="${GREEN}${BOLD}● Running${RESET}"
    else
        service_status="${RED}${BOLD}● Stopped${RESET}"
    fi

    echo -e "  ${BOLD}${CYAN}AUTOSYNC FILTER${RESET}$(printf '%*s' $((cols - 38)) '')${service_status}\033[K"
    echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 $((cols - 4))))${RESET}\033[K"
    echo -e "  ${DIM}Use ↑/↓ to navigate, SPACE to toggle, Esc to go back${RESET}\033[K"
    echo -e "\033[K"

    # Clamp cursor
    local total=${#FILTER_ITEMS[@]}
    if [ "$total" -eq 0 ]; then
        echo -e "  ${DIM}No sync data yet. Run a sync first.${RESET}\033[K"
        echo -ne "\033[J"
        tput cup $((rows - 2)) 0
        echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 $((cols - 4))))${RESET}\033[K"
        tput cup $((rows - 1)) 0
        echo -ne "  ${REVERSE} Esc ${RESET} Back\033[K"
        return
    fi
    [ "$FILTER_CURSOR" -ge "$total" ] && FILTER_CURSOR=$((total - 1))
    [ "$FILTER_CURSOR" -lt 0 ] && FILTER_CURSOR=0

    local home_short="~"
    local i
    for (( i=0; i<total; i++ )); do
        local item="${FILTER_ITEMS[$i]}"
        local type="${FILTER_TYPES[$i]}"
        local cursor_mark="  "
        [ "$i" -eq "$FILTER_CURSOR" ] && cursor_mark="${REVERSE}▶${RESET} "

        if [ "$type" = "host" ]; then
            local host="$item"
            local display_host="${host#*@}"
            local status_mark
            if is_host_disabled "$host"; then
                status_mark="${RED}✗ paused${RESET}"
            else
                status_mark="${GREEN}✓ enabled${RESET}"
            fi
            printf "  ${cursor_mark}${BOLD}%-$((cols - 22))s${RESET} [%b]\033[K\n" "$display_host" "$status_mark"
        else
            local host="${item%%|*}"
            local folder="${item#*|}"
            local display_folder="${folder/#$HOME/$home_short}"
            local status_mark
            if is_host_disabled "$host"; then
                status_mark="${DIM}✗${RESET}"
            elif is_folder_disabled "$host" "$folder"; then
                status_mark="${RED}✗${RESET}"
            else
                status_mark="${GREEN}✓${RESET}"
            fi
            printf "  ${cursor_mark}    %-$((cols - 26))s [%b]\033[K\n" "$display_folder" "$status_mark"
        fi
    done

    echo -ne "\033[J"

    # Footer
    tput cup $((rows - 3)) 0
    local now
    now=$(date +%s)
    if [ -n "$MESSAGE" ] && [ $((now - MESSAGE_TIME)) -lt 5 ]; then
        echo -e "  ${YELLOW}${MESSAGE}${RESET}\033[K"
    else
        echo -e "\033[K"
    fi
    tput cup $((rows - 2)) 0
    echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 $((cols - 4))))${RESET}\033[K"
    tput cup $((rows - 1)) 0
    echo -ne "  ${REVERSE} ↑/↓ ${RESET} Navigate  ${REVERSE} ␣ ${RESET} Toggle  ${REVERSE} Esc ${RESET} Back\033[K"
}

handle_key_filter() {
    local key="$1"
    local total=${#FILTER_ITEMS[@]}

    case "$key" in
        q|Q|$'\e')
            MODE="dashboard"
            ;;
        A)  # Up arrow
            FILTER_CURSOR=$((FILTER_CURSOR - 1))
            [ "$FILTER_CURSOR" -lt 0 ] && FILTER_CURSOR=0
            ;;
        B)  # Down arrow
            FILTER_CURSOR=$((FILTER_CURSOR + 1))
            [ "$FILTER_CURSOR" -ge "$total" ] && FILTER_CURSOR=$((total - 1))
            ;;
        " ")
            [ "$total" -eq 0 ] && return
            local item="${FILTER_ITEMS[$FILTER_CURSOR]}"
            local type="${FILTER_TYPES[$FILTER_CURSOR]}"
            if [ "$type" = "host" ]; then
                toggle_host "$item"
            else
                local host="${item%%|*}"
                local folder="${item#*|}"
                toggle_folder "$host" "$folder"
            fi
            ;;
    esac
}

is_service_installed() {
    [ -f "$SERVICE_FILE" ]
}

is_service_running() {
    systemctl --user is-active autosync &>/dev/null
}

is_service_enabled() {
    systemctl --user is-enabled autosync &>/dev/null
}

do_install() {
    mkdir -p "$(dirname "$SERVICE_FILE")"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Two-way folder sync via Unison over Tailscale
After=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/autosync-watch.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable autosync
    show_message "Service installed and enabled"
}

do_uninstall() {
    systemctl --user stop autosync 2>/dev/null
    systemctl --user disable autosync 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl --user daemon-reload
    show_message "Service uninstalled"
}

do_start() {
    systemctl --user start autosync
    show_message "Service started"
}

do_stop() {
    systemctl --user stop autosync
    show_message "Service stopped"
}

do_restart() {
    systemctl --user restart autosync
    show_message "Service restarted"
}

do_manual_sync() {
    systemctl --user kill --signal=USR1 autosync
    show_message "Manual sync triggered"
}

draw_dashboard() {
    local cols rows
    cols=$(tput cols)
    rows=$(tput lines)
    tput cup 0 0

    # ── Header ──
    local service_status
    if ! is_service_installed; then
        service_status="${DIM}○ Not Installed${RESET}"
    elif is_service_running; then
        service_status="${GREEN}${BOLD}● Running${RESET}"
    else
        service_status="${RED}${BOLD}● Stopped${RESET}"
    fi

    local state_info=""
    if [ -f "$STATE_FILE" ]; then
        local state ts
        IFS='|' read -r state ts < "$STATE_FILE"
        if [ "$state" = "syncing" ]; then
            state_info="  ${YELLOW}⟳ Syncing...${RESET}"
        else
            state_info="  ${DIM}Watching for changes${RESET}"
        fi
    fi

    echo -e "  ${BOLD}${CYAN}AUTOSYNC MONITOR${RESET}${state_info}$(printf '%*s' $((cols - 40)) '')${service_status}\033[K"
    echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 $((cols - 4))))${RESET}\033[K"

    # ── Folder status table ──
    local home_short="~"
    local host_col=16
    printf "  ${BOLD}%-${host_col}s %-$((cols - host_col - 34))s  %-10s %-8s %s${RESET}\033[K\n" "Host" "Folder" "Last Sync" "Status" "Trigger"

    if [ -f "$STATUS_FILE" ]; then
        while IFS='|' read -r host folder status ts trigger; do
            [ -z "$host" ] && continue
            local display_host="${host#*@}"
            if [ ${#display_host} -gt $((host_col - 1)) ]; then
                display_host="${display_host:0:$((host_col - 3))}.."
            fi
            local display_folder="${folder/#$HOME/$home_short}"
            local max_folder_len=$((cols - host_col - 36))
            if [ ${#display_folder} -gt $max_folder_len ]; then
                display_folder="${display_folder:0:$((max_folder_len - 2))}.."
            fi
            local time_part="${ts##* }"
            local status_display
            if is_host_disabled "$host" || is_folder_disabled "$host" "$folder"; then
                status_display="${DIM}⏸ paused${RESET}"
            elif [ "$status" = "OK" ]; then
                status_display="${GREEN}✓ OK${RESET}    "
            else
                status_display="${RED}✗ FAIL${RESET}  "
            fi
            printf "  %-${host_col}s %-$((cols - host_col - 34))s  ${DIM}%-10s${RESET} %b ${DIM}%s${RESET}\033[K\n" \
                "$display_host" "$display_folder" "$time_part" "$status_display" "$trigger"
        done < "$STATUS_FILE"
    else
        echo -e "  ${DIM}No sync data yet. Waiting for first sync...${RESET}\033[K"
    fi

    echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 $((cols - 4))))${RESET}\033[K"

    # ── Recent activity ──
    echo -e "  ${BOLD}Recent Activity${RESET}\033[K"
    echo -e "\033[K"

    if [ -f "$LOG_FILE" ]; then
        local folder_count=0
        [ -f "$STATUS_FILE" ] && folder_count=$(wc -l < "$STATUS_FILE")
        [ "$folder_count" -lt 1 ] && folder_count=1
        # Reserve 3 lines for footer
        local log_rows=$((rows - 10 - folder_count))
        [ "$log_rows" -lt 3 ] && log_rows=3

        grep "^\[" "$LOG_FILE" | tail -n "$log_rows" | tac | while IFS= read -r line; do
            line="${line//$HOME/\~}"
            if [ ${#line} -gt $((cols - 4)) ]; then
                line="${line:0:$((cols - 7))}..."
            fi
            if [[ "$line" == *"Sync OK"* ]]; then
                echo -e "  ${GREEN}${line}${RESET}\033[K"
            elif [[ "$line" == *"Sync FAILED"* ]]; then
                echo -e "  ${RED}${line}${RESET}\033[K"
            elif [[ "$line" == *"Change detected"* ]]; then
                echo -e "  ${YELLOW}${line}${RESET}\033[K"
            elif [[ "$line" == *"=== autosync"* ]]; then
                echo -e "  ${CYAN}${line}${RESET}\033[K"
            else
                echo -e "  ${DIM}${line}${RESET}\033[K"
            fi
        done
    else
        echo -e "  ${DIM}No log file found.${RESET}\033[K"
    fi

    # Clear any leftover lines
    echo -ne "\033[J"

    # ── Footer ──
    draw_footer "$cols" "$rows"
}

draw_log() {
    local cols rows
    cols=$(tput cols)
    rows=$(tput lines)
    tput cup 0 0

    echo -e "  ${BOLD}${CYAN}AUTOSYNC LOG${RESET}$(printf '%*s' $((cols - 20)) '')${DIM}$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) lines${RESET}\033[K"
    echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 $((cols - 4))))${RESET}\033[K"

    local log_rows=$((rows - 5))
    [ "$log_rows" -lt 3 ] && log_rows=3

    if [ -f "$LOG_FILE" ]; then
        local total_lines
        total_lines=$(wc -l < "$LOG_FILE")
        local start_line
        if [ "$LOG_OFFSET" -gt 0 ]; then
            # Scrolled up
            local end_line=$((total_lines - LOG_OFFSET))
            [ "$end_line" -lt "$log_rows" ] && end_line=$log_rows
            start_line=$((end_line - log_rows + 1))
            [ "$start_line" -lt 1 ] && start_line=1
            sed -n "${start_line},${end_line}p" "$LOG_FILE" | while IFS= read -r line; do
                line="${line//$HOME/\~}"
                if [ ${#line} -gt $((cols - 4)) ]; then
                    line="${line:0:$((cols - 7))}..."
                fi
                _color_log_line "$line" "$cols"
            done
        else
            # At bottom (latest)
            tail -n "$log_rows" "$LOG_FILE" | while IFS= read -r line; do
                line="${line//$HOME/\~}"
                if [ ${#line} -gt $((cols - 4)) ]; then
                    line="${line:0:$((cols - 7))}..."
                fi
                _color_log_line "$line" "$cols"
            done
        fi
    else
        echo -e "  ${DIM}No log file found.${RESET}\033[K"
    fi

    echo -ne "\033[J"

    # Footer for log view
    tput cup $((rows - 2)) 0
    echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 $((cols - 4))))${RESET}\033[K"
    tput cup $((rows - 1)) 0
    local scroll_hint=""
    [ "$LOG_OFFSET" -gt 0 ] && scroll_hint="  ${YELLOW}↑ scrolled up ${LOG_OFFSET} lines${RESET}"
    echo -ne "  ${REVERSE} ↑/↓ ${RESET} Scroll  ${REVERSE} g/G ${RESET} Top/Bottom  ${REVERSE} Esc ${RESET} Back${scroll_hint}\033[K"
}

_color_log_line() {
    local line="$1" cols="$2"
    if [[ "$line" == *"Sync OK"* ]]; then
        echo -e "  ${GREEN}${line}${RESET}\033[K"
    elif [[ "$line" == *"Sync FAILED"* || "$line" == *"ERROR"* ]]; then
        echo -e "  ${RED}${line}${RESET}\033[K"
    elif [[ "$line" == *"Change detected"* ]]; then
        echo -e "  ${YELLOW}${line}${RESET}\033[K"
    elif [[ "$line" == *"=== autosync"* ]]; then
        echo -e "  ${CYAN}${line}${RESET}\033[K"
    elif [[ "$line" == *"Syncing"* ]]; then
        echo -e "  ${WHITE}${line}${RESET}\033[K"
    else
        echo -e "  ${DIM}${line}${RESET}\033[K"
    fi
}

draw_footer() {
    local cols="$1" rows="$2"

    # Message line
    tput cup $((rows - 3)) 0
    local now
    now=$(date +%s)
    if [ -n "$MESSAGE" ] && [ $((now - MESSAGE_TIME)) -lt 5 ]; then
        echo -e "  ${YELLOW}${MESSAGE}${RESET}\033[K"
    elif [ -n "$CONFIRM_ACTION" ]; then
        echo -e "  ${YELLOW}${BOLD}Confirm ${CONFIRM_ACTION}? [y/N]${RESET}\033[K"
    else
        echo -e "\033[K"
    fi

    # Separator
    tput cup $((rows - 2)) 0
    echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 $((cols - 4))))${RESET}\033[K"

    # Key hints
    tput cup $((rows - 1)) 0
    local keys=""
    if is_service_installed; then
        if is_service_running; then
            keys="${REVERSE} ␣ ${RESET} Sync  ${REVERSE} s ${RESET} Stop  ${REVERSE} r ${RESET} Restart  ${REVERSE} u ${RESET} Uninstall"
        else
            keys="${REVERSE} s ${RESET} Start  ${REVERSE} u ${RESET} Uninstall"
        fi
    else
        keys="${REVERSE} i ${RESET} Install"
    fi
    echo -ne "  ${keys}  ${REVERSE} f ${RESET} Filter  ${REVERSE} l ${RESET} Logs  ${REVERSE} q ${RESET} Quit\033[K"
}

handle_key_dashboard() {
    local key="$1"

    # Handle confirmation first
    if [ -n "$CONFIRM_ACTION" ]; then
        if [ "$key" = "y" ] || [ "$key" = "Y" ]; then
            case "$CONFIRM_ACTION" in
                stop)      do_stop ;;
                uninstall) do_uninstall ;;
            esac
        else
            show_message "Cancelled"
        fi
        CONFIRM_ACTION=""
        return
    fi

    case "$key" in
        i|I)
            if ! is_service_installed; then
                do_install
            else
                show_message "Service already installed"
            fi
            ;;
        u|U)
            if is_service_installed; then
                CONFIRM_ACTION="uninstall"
            else
                show_message "Service not installed"
            fi
            ;;
        s|S)
            if is_service_installed; then
                if is_service_running; then
                    CONFIRM_ACTION="stop"
                else
                    do_start
                fi
            else
                show_message "Service not installed. Press i to install."
            fi
            ;;
        r|R)
            if is_service_installed && is_service_running; then
                do_restart
            else
                show_message "Service not running"
            fi
            ;;
        " ")
            if is_service_running; then
                do_manual_sync
            else
                show_message "Service not running"
            fi
            ;;
        f|F)
            MODE="filter"
            FILTER_CURSOR=0
            build_filter_items
            ;;
        l|L)
            MODE="log"
            LOG_OFFSET=0
            ;;
        q|Q)
            exit 0
            ;;
    esac
}

handle_key_log() {
    local key="$1"

    case "$key" in
        q|Q|$'\e')
            MODE="dashboard"
            ;;
        g)
            # Go to top
            if [ -f "$LOG_FILE" ]; then
                local total
                total=$(wc -l < "$LOG_FILE")
                local rows
                rows=$(tput lines)
                local log_rows=$((rows - 5))
                LOG_OFFSET=$((total - log_rows))
                [ "$LOG_OFFSET" -lt 0 ] && LOG_OFFSET=0
            fi
            ;;
        G)
            # Go to bottom
            LOG_OFFSET=0
            ;;
        A)
            # Up arrow (escape sequence handled below)
            LOG_OFFSET=$((LOG_OFFSET + 5))
            if [ -f "$LOG_FILE" ]; then
                local total
                total=$(wc -l < "$LOG_FILE")
                local rows
                rows=$(tput lines)
                local max_offset=$((total - (rows - 5)))
                [ "$max_offset" -lt 0 ] && max_offset=0
                [ "$LOG_OFFSET" -gt "$max_offset" ] && LOG_OFFSET=$max_offset
            fi
            ;;
        B)
            # Down arrow
            LOG_OFFSET=$((LOG_OFFSET - 5))
            [ "$LOG_OFFSET" -lt 0 ] && LOG_OFFSET=0
            ;;
    esac
}

# ── Main loop ──
while true; do
    if [ "$MODE" = "log" ]; then
        draw_log
    elif [ "$MODE" = "filter" ]; then
        draw_filter
    else
        draw_dashboard
    fi

    # Wait for input with 2s timeout (IFS= preserves space character)
    IFS= read -rsn1 -t 2 key
    if [ -z "$key" ]; then
        continue
    fi

    # Handle escape sequences (arrow keys)
    if [ "$key" = $'\e' ]; then
        read -rsn1 -t 0.1 seq1
        if [ "$seq1" = "[" ]; then
            read -rsn1 -t 0.1 seq2
            key="$seq2"  # A=up, B=down
        else
            # Plain Escape
            if [ "$MODE" = "log" ] || [ "$MODE" = "filter" ]; then
                MODE="dashboard"
            fi
            continue
        fi
    fi

    if [ "$MODE" = "log" ]; then
        handle_key_log "$key"
    elif [ "$MODE" = "filter" ]; then
        handle_key_filter "$key"
    else
        handle_key_dashboard "$key"
    fi
done
