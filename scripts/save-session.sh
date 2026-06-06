#!/usr/bin/env bash
# Save current Yakuake session state (tab names, order, working directories)
# to a JSON file that restore-session.sh can read.

set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yakuake-session"
STATE_FILE="$STATE_DIR/session.json"
BACKUP_DIR="$STATE_DIR/backups"
FLAG_FILE="$STATE_DIR/restore-in-progress"
MAX_BACKUPS=10
RESURRECT_SAVE="$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh"

mkdir -p "$STATE_DIR"

# Clean up orphan tmux sessions: yakuake-* sessions that aren't connected
# to any Yakuake tab. These accumulate when tabs are closed (tmux sessions
# outlive their clients by default).
#
# Matching strategy (in order of preference):
#   1. KONSOLE_DBUS_SESSION env var: each tmux client's process has this in
#      /proc/<pid>/environ, mapping directly to a Konsole /Sessions/N path.
#      This is the most reliable method when tmux runs inside Konsole.
#   2. Process tree walk: the Konsole-reported PID is the shell, not the
#      tmux client. Walk ancestors to find a tmux client PID.
#   3. D-Bus processId: match the Konsole session's reported PID directly.
#
# Safeguards:
#   - Skip during restore (FLAG_FILE present)
#   - Skip if Yakuake D-Bus is not responsive
#   - If a candidate orphan has ANY client attached, log warning and skip
#     (tmux new-session creates the session and attaches the client atomically,
#     so during normal tab creation there's no real window without a client)
cleanup_orphan_tmux_sessions() {
    [[ -f "$FLAG_FILE" ]] && return 0
    pgrep -x 'yakuake|\.yakuake-wrappe' &>/dev/null || return 0
    qdbus org.kde.yakuake /yakuake/sessions sessionIdList &>/dev/null || return 0
    tmux list-sessions &>/dev/null || return 0

    # Build the set of Konsole /Sessions/N paths that exist in Yakuake
    local konsole_paths
    konsole_paths=$(qdbus org.kde.yakuake 2>/dev/null | grep -E '^/Sessions/[0-9]+$' || true)
    [[ -z "$konsole_paths" ]] && return 0

    declare -A active_konsole_sids=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local sid
        sid=$(echo "$path" | grep -oE '[0-9]+$')
        [[ -n "$sid" ]] && active_konsole_sids["$sid"]=1
    done <<< "$konsole_paths"

    # Strategy 1: Match tmux clients to Konsole sessions via KONSOLE_DBUS_SESSION
    # Each tmux client's process has KONSOLE_DBUS_SESSION=/Sessions/N in its
    # environment. This directly links the client to the Konsole session.
    declare -A in_use=()
    local clients_data
    clients_data=$(tmux list-clients -F '#{client_pid} #{session_name}' 2>/dev/null || true)

    while IFS=' ' read -r pid session; do
        [[ -z "$pid" ]] && continue
        local konsole_session
        konsole_session=$(cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n' | grep '^KONSOLE_DBUS_SESSION=' | head -1 | cut -d= -f2 || true)
        if [[ -n "$konsole_session" ]] && [[ "$konsole_session" =~ /Sessions/([0-9]+) ]]; then
            local sid="${BASH_REMATCH[1]}"
            if [[ -n "${active_konsole_sids[$sid]:-}" ]]; then
                in_use["$session"]=1
                continue
            fi
        fi
    done <<< "$clients_data"

    # Strategy 2: Walk process tree from Konsole PIDs to find tmux client ancestors
    if [[ ${#in_use[@]} -eq 0 ]]; then
        declare -A pid_for_path=()
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            local pid
            pid=$(qdbus org.kde.yakuake "$path" processId 2>/dev/null || echo "")
            [[ -z "$pid" ]] && continue
            pid_for_path["$path"]="$pid"
            local session
            session=$(echo "$clients_data" | awk -v p="$pid" '$1==p {print $2; exit}')
            [[ -n "$session" ]] && in_use["$session"]=1
        done <<< "$konsole_paths"

        if [[ ${#in_use[@]} -eq 0 ]]; then
            while IFS= read -r path; do
                [[ -z "$path" ]] && continue
                local pid="${pid_for_path[$path]:-}"
                [[ -z "$pid" ]] && continue
                local ppid="$pid"
                for _ in $(seq 1 5); do
                    local ppid_val
                    ppid_val=$(ps -o ppid= -p "$ppid" 2>/dev/null | tr -d ' ')
                    [[ -z "$ppid_val" ]] && break
                    local match
                    match=$(echo "$clients_data" | awk -v p="$ppid_val" '$1==p {print $2; exit}')
                    if [[ -n "$match" ]]; then
                        in_use["$match"]=1
                        break
                    fi
                    ppid="$ppid_val"
                done
            done <<< "$konsole_paths"
        fi

        if [[ ${#in_use[@]} -eq 0 ]]; then
            echo "Cleanup: Konsole has sessions but no tmux clients matched; skipping cleanup" >&2
            return 0
        fi
    fi

    local killed=0

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$name" != yakuake-* ]] && continue
        [[ -n "${in_use[$name]:-}" ]] && continue

        local clients_for_session
        clients_for_session=$(tmux list-clients -t "$name" -F '#{client_pid} #{client_tty}' 2>/dev/null || true)
        if [[ -n "$clients_for_session" ]]; then
            echo "WARNING: tmux session '$name' has clients but didn't match any Yakuake tab; skipping" >&2
            continue
        fi

        if tmux kill-session -t "$name" 2>/dev/null; then
            killed=$((killed + 1))
        fi
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

    (( killed > 0 )) && echo "Cleaned up $killed orphan tmux session(s)"
    return 0
}

cleanup_orphan_tmux_sessions

# Save tmux state (while everything is alive). This is critical at
# shutdown — if Yakuake dies before we get here, we still want tmux state.
# Run it with a timeout so a hung tmux can't block the Yakuake save.
if [[ -x "$RESURRECT_SAVE" ]] && tmux list-sessions &>/dev/null; then
    timeout 10 tmux run-shell "$RESURRECT_SAVE" 2>/dev/null \
        && echo "Saved tmux-resurrect state" \
        || echo "Warning: tmux-resurrect save failed or timed out" >&2
fi

# Check that Yakuake process is actually running before querying D-Bus.
# (D-Bus auto-activation would restart Yakuake if we queried it while dead.)
if ! pgrep -x 'yakuake|\.yakuake-wrappe' &>/dev/null; then
    echo "Yakuake is not running, nothing to save." >&2
    exit 1
fi

# Build a map from Konsole session ID -> tmux session name by reading
# KONSOLE_DBUS_SESSION from each tmux client's /proc/<pid>/environ.
# This correctly handles cases where session names don't match tab indices
# (e.g., after a failed restore that created yakuake-16..30 instead of 0..14).
declare -A konsole_sid_to_tmux=()
clients_data=$(tmux list-clients -F '#{client_pid} #{session_name}' 2>/dev/null || true)
while IFS=' ' read -r pid session; do
    [[ -z "$pid" ]] && continue
    konsole_env=$(cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n' | grep '^KONSOLE_DBUS_SESSION=' | head -1 || true)
    if [[ -n "$konsole_env" ]] && [[ "$konsole_env" =~ /Sessions/([0-9]+) ]]; then
        konsole_sid_to_tmux["${BASH_REMATCH[1]}"]="$session"
    fi
done <<< "$clients_data"

# Get tabs in visual order using sessionAtTab (sessionIdList is creation order, not tab order)
session_id_list=$(qdbus org.kde.yakuake /yakuake/sessions sessionIdList)
tab_count=$(echo "$session_id_list" | tr ',' '\n' | wc -l)

tabs_json="[]"
index=0

for ((i=0; i<tab_count; i++)); do
    sid=$(qdbus org.kde.yakuake /yakuake/tabs sessionAtTab "$i")

    title=$(qdbus org.kde.yakuake /yakuake/tabs tabTitle "$sid" 2>/dev/null || echo "")

    # Map session id -> Konsole terminal id(s) for /Sessions/N D-Bus paths.
    # Terminal IDs are independent of session IDs (split panes consume IDs),
    # so don't assume sid+1.
    terminal_ids=$(qdbus org.kde.yakuake /yakuake/sessions terminalIdsForSessionId "$sid" 2>/dev/null || echo "")
    konsole_sid=$(echo "$terminal_ids" | cut -d, -f1)
    [[ -z "$konsole_sid" ]] && konsole_sid=$((sid + 1))

    # Determine the actual tmux session name for this tab.
    # Try: Konsole session -> tmux session map (handles misaligned names).
    # Fallback: canonical name yakuake-$i.
    actual_tmux_session="yakuake-${i}"
    if [[ -n "${konsole_sid_to_tmux[$konsole_sid]:-}" ]]; then
        actual_tmux_session="${konsole_sid_to_tmux[$konsole_sid]}"
    fi

    # Get the working directory. If the terminal is running tmux, query tmux
    # for the pane's cwd (since /proc/<tmux-client-pid>/cwd is just where
    # tmux was launched from, not the shell's actual directory).
    cwd="$HOME"

    tmux_cwd=$(tmux display-message -t "$actual_tmux_session" -p '#{pane_current_path}' 2>/dev/null || echo "")
    if [[ -n "$tmux_cwd" ]]; then
        cwd="$tmux_cwd"
    else
        # Try canonical name as fallback (may exist even if map didn't find it)
        if [[ "$actual_tmux_session" != "yakuake-${i}" ]]; then
            tmux_cwd=$(tmux display-message -t "yakuake-${i}" -p '#{pane_current_path}' 2>/dev/null || echo "")
            [[ -n "$tmux_cwd" ]] && cwd="$tmux_cwd"
        fi
        # Fallback: read from /proc for non-tmux terminals
        if [[ "$cwd" == "$HOME" ]]; then
            pid=$(qdbus org.kde.yakuake /Sessions/$konsole_sid processId 2>/dev/null || echo "")
            if [[ -n "$pid" ]] && [[ -d "/proc/$pid/cwd" ]]; then
                cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "$HOME")
            fi
        fi
    fi

    tabs_json=$(echo "$tabs_json" | jq \
        --argjson idx "$index" \
        --arg title "$title" \
        --arg cwd "$cwd" \
        --arg sid "$sid" \
        --arg tids "$terminal_ids" \
        --arg tmux_session "$actual_tmux_session" \
        '. + [{
            "index": $idx,
            "session_id": ($sid | tonumber),
            "title": $title,
            "cwd": $cwd,
            "terminal_ids": $tids,
            "tmux_session": $tmux_session
        }]')

    index=$((index + 1))
done

# Rotate backups before overwriting
if [[ -f "$STATE_FILE" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp "$STATE_FILE" "$BACKUP_DIR/session-$(date +%Y%m%dT%H%M%S).json"

    # Prune old backups, keep the most recent $MAX_BACKUPS
    ls -1t "$BACKUP_DIR"/session-*.json 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f
fi

# Write with metadata
jq -n \
    --arg timestamp "$(date -Iseconds)" \
    --argjson tabs "$tabs_json" \
    '{
        "version": 1,
        "saved_at": $timestamp,
        "tabs": $tabs
    }' > "$STATE_FILE"

echo "Saved $index tabs to $STATE_FILE"
