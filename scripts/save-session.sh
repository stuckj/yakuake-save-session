#!/usr/bin/env bash
# Save current Yakuake session state (tab names, order, working directories)
# to a JSON file that restore-session.sh can read.

set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yakuake-session"
STATE_FILE="$STATE_DIR/session.json"
BACKUP_DIR="$STATE_DIR/backups"
FLAG_FILE="$STATE_DIR/restore-in-progress"
CANDIDATE_FILE="$STATE_DIR/orphan-candidates"
MAX_BACKUPS=10
RESURRECT_SAVE="$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh"

# qdbus (Qt 6.11 / qttools) segfaults in its atexit handler AFTER it has
# already produced correct output (QMetaType::unregisterMetaType, reached via
# registerComplexDBusType's hash destructor during exit()). The D-Bus call
# itself succeeds; only the teardown crashes, so the process exits via SIGSEGV
# (status >= 128) and dumps core. Wrap it to (a) disable the core dump and
# (b) treat a signal-kill as success so `set -e` doesn't abort on a crash that
# happened after the work was done.
_QDBUS_BIN="$(type -P qdbus || true)"
qdbus() {
    local out rc
    out="$(ulimit -c 0; "$_QDBUS_BIN" "$@" 2>/dev/null)"
    rc=$?
    [[ -n "$out" ]] && printf '%s\n' "$out"
    (( rc >= 128 )) && return 0
    return "$rc"
}

# busctl (systemd's D-Bus client) is used for calls on the embedded Konsole
# objects (/Windows/N, /Sessions/N). Those crash qdbus via the same Qt 6.11
# atexit segfault, but busctl is plain C and returns cleanly.
_BUSCTL="$(type -P busctl || true)"

# currentSession(): the active Konsole session id (the N in /Sessions/N) for a
# Konsole window object /Windows/$1.
konsole_window_session() {
    [[ -n "$_BUSCTL" ]] || return 1
    "$_BUSCTL" --user call org.kde.yakuake "/Windows/$1" \
        org.kde.konsole.Window currentSession 2>/dev/null | awk '{print $2}'
}

# List the numeric ids of all Konsole window objects (/Windows/N).
list_konsole_windows() {
    [[ -n "$_BUSCTL" ]] || return 1
    "$_BUSCTL" --user tree org.kde.yakuake 2>/dev/null \
        | grep -oE '/Windows/[0-9]+' | grep -oE '[0-9]+$' | sort -n -u
}

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

    # Two-strike reaping. A yakuake-* session is only killed if it was a
    # client-less orphan candidate on the PREVIOUS run as well as this one.
    # This prevents the destructive loop where a tab's session is briefly
    # detached while its profile script reattaches after a restore: the first
    # save marks it a candidate (does NOT kill it), and by the next save it has
    # reattached and is no longer a candidate. Genuine orphans from closed tabs
    # stay detached across both runs and get reaped.
    #
    # Candidates are tagged with the tmux server PID. A reboot starts a new
    # server (new PID), which invalidates the previous candidate list, so the
    # first save after a reboot never reaps anything.
    local server_pid
    server_pid=$(tmux display-message -p '#{pid}' 2>/dev/null || echo "")

    declare -A prev_candidates=()
    if [[ -f "$CANDIDATE_FILE" ]]; then
        local prev_pid
        prev_pid=$(head -1 "$CANDIDATE_FILE" 2>/dev/null || echo "")
        if [[ -n "$server_pid" && "$prev_pid" == "$server_pid" ]]; then
            while IFS= read -r c; do
                [[ -n "$c" ]] && prev_candidates["$c"]=1
            done < <(tail -n +2 "$CANDIDATE_FILE" 2>/dev/null)
        fi
    fi

    local killed=0
    local -a current_candidates=()

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

        # Client-less and unmatched: an orphan candidate. Only reap on the
        # second consecutive sighting (same tmux server).
        current_candidates+=("$name")
        if [[ -n "${prev_candidates[$name]:-}" ]]; then
            if tmux kill-session -t "$name" 2>/dev/null; then
                killed=$((killed + 1))
            fi
        fi
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

    # Persist this run's candidates for the next run's two-strike check.
    {
        echo "$server_pid"
        ((${#current_candidates[@]})) && printf '%s\n' "${current_candidates[@]}"
    } > "$CANDIDATE_FILE"

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

# Get tabs in visual order (sessionAtTab; sessionIdList is creation order).
session_id_list=$(qdbus org.kde.yakuake /yakuake/sessions sessionIdList)
tab_count=$(echo "$session_id_list" | tr ',' '\n' | wc -l)

if [[ "$tab_count" -le 0 ]]; then
    echo "No tabs to save." >&2
    exit 0
fi

declare -a tab_ysid=() tab_title=()
for ((i=0; i<tab_count; i++)); do
    sid=$(qdbus org.kde.yakuake /yakuake/tabs sessionAtTab "$i")
    tab_ysid[i]="$sid"
    tab_title[i]=$(qdbus org.kde.yakuake /yakuake/tabs tabTitle "$sid" 2>/dev/null || echo "")
done

# --- Reliable tab -> tmux mapping via the Konsole window bridge ---
# Yakuake's tab API only exposes internal session/terminal IDs, which do NOT
# match Konsole's /Sessions/N paths (they are independent counters). But each
# tab is backed by a Konsole window object at /Windows/(Ysid + k) for a
# constant offset k; its currentSession() returns the real /Sessions/N, which
# the KONSOLE_DBUS_SESSION env map (konsole_sid_to_tmux) turns into a tmux
# session name. The offset k is discovered dynamically and only accepted if it
# yields a clean assignment (every tab's window exists and no two tabs share a
# tmux session), so a wrong guess can never silently corrupt the mapping.
declare -A window_konsole=() window_exists=()
while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    window_exists["$m"]=1
    n=$(konsole_window_session "$m")
    [[ -n "$n" ]] && window_konsole["$m"]="$n"
done < <(list_konsole_windows)

declare -A tab_tmux=()
mapping_ok=0
if ((${#window_exists[@]} > 0)); then
    # Candidate offsets: tab 0's window must be one of the existing windows.
    declare -a candidate_ks=()
    for m in "${!window_exists[@]}"; do
        candidate_ks+=("$((m - ${tab_ysid[0]}))")
    done
    for k in $(printf '%s\n' "${candidate_ks[@]}" | sort -n -u); do
        declare -A used=() try=()
        ok=1
        for ((i=0; i<tab_count; i++)); do
            m=$(( ${tab_ysid[i]} + k ))
            if [[ -z "${window_exists[$m]:-}" ]]; then ok=0; break; fi
            t=""
            n="${window_konsole[$m]:-}"
            [[ -n "$n" ]] && t="${konsole_sid_to_tmux[$n]:-}"
            if [[ -n "$t" ]]; then
                if [[ -n "${used[$t]:-}" ]]; then ok=0; break; fi
                used["$t"]=1
            fi
            try["$i"]="$t"
        done
        if (( ok )); then
            for ((i=0; i<tab_count; i++)); do tab_tmux[$i]="${try[$i]:-}"; done
            mapping_ok=1
            break
        fi
        unset used try
    done
fi

if (( ! mapping_ok )); then
    echo "Warning: could not build a reliable tab->tmux mapping (busctl bridge unavailable or ambiguous, e.g. split panes); keeping previous session.json" >&2
    exit 0
fi

# Build the tab list. Content is keyed by stable tmux session NAME plus the
# current tab title, so restore is fully PID-independent.
tabs_json="[]"
for ((i=0; i<tab_count; i++)); do
    title="${tab_title[i]}"
    tmux_session="${tab_tmux[$i]:-}"
    cwd="$HOME"
    if [[ -n "$tmux_session" ]]; then
        tmux_cwd=$(tmux display-message -t "$tmux_session" -p '#{pane_current_path}' 2>/dev/null || echo "")
        [[ -n "$tmux_cwd" ]] && cwd="$tmux_cwd"
    fi
    tabs_json=$(echo "$tabs_json" | jq \
        --argjson idx "$i" \
        --arg title "$title" \
        --arg cwd "$cwd" \
        --arg tmux_session "$tmux_session" \
        '. + [{
            "index": $idx,
            "title": $title,
            "cwd": $cwd,
            "tmux_session": $tmux_session
        }]')
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
        "version": 2,
        "saved_at": $timestamp,
        "tabs": $tabs
    }' > "$STATE_FILE"

echo "Saved $tab_count tabs to $STATE_FILE"
