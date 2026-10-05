#!/usr/bin/env bash
# Save current Yakuake session state (tab names, order, working directories)
# to a JSON file that restore-session.sh can read.

set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yakuake-session"
STATE_FILE="$STATE_DIR/session.json"
BACKUP_DIR="$STATE_DIR/backups"
MAX_BACKUPS=10

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

mkdir -p "$STATE_DIR"

# Check that Yakuake process is actually running before querying D-Bus.
# (D-Bus auto-activation would restart Yakuake if we queried it while dead.)
# Matches Ubuntu's "yakuake" and NixOS's truncated ".yakuake-wrappe" — Linux
# caps /proc/PID/comm at 15 chars and NixOS wraps binaries as ".NAME-wrapped".
if ! pgrep -x 'yakuake|\.yakuake-wrappe' &>/dev/null; then
    echo "Yakuake is not running, nothing to save." >&2
    exit 1
fi

# Tabs in visual order. sessionIdList is creation order, so walk sessionAtTab
# instead — the saved order is what the user sees, not what they created.
session_id_list=$(qdbus org.kde.yakuake /yakuake/sessions sessionIdList)
tab_count=$(echo "$session_id_list" | tr ',' '\n' | wc -l)

if [[ "$tab_count" -le 0 ]]; then
    echo "No tabs to save." >&2
    exit 0
fi

# Yakuake terminal IDs and Konsole's /Sessions/N paths are independent counters
# that differ by a constant — on a fresh Yakuake it is 1 (terminal 3 is
# /Sessions/4), but it is NOT guaranteed, so discover it rather than assume.
# A candidate offset is only accepted if EVERY tab's terminal maps to a Konsole
# session that actually exists, which makes a wrong guess fail loudly here
# instead of silently attributing each tab the previous tab's directory.
declare -a tab_sid=() tab_title=() tab_tid=()
for ((i=0; i<tab_count; i++)); do
    sid=$(qdbus org.kde.yakuake /yakuake/tabs sessionAtTab "$i")
    tab_sid[i]="$sid"
    tab_title[i]=$(qdbus org.kde.yakuake /yakuake/tabs tabTitle "$sid" 2>/dev/null || echo "")
    tid=$(qdbus org.kde.yakuake /yakuake/sessions terminalIdsForSessionId "$sid" 2>/dev/null | cut -d, -f1)
    tab_tid[i]="${tid:-$sid}"
done

konsole_sids=$(qdbus org.kde.yakuake 2>/dev/null | grep -oE '^/Sessions/[0-9]+$' | grep -oE '[0-9]+$' | sort -n)
declare -A konsole_exists=()
while IFS= read -r n; do
    [[ -n "$n" ]] && konsole_exists["$n"]=1
done <<< "$konsole_sids"

offset=""
for k in 1 0 $(seq 2 20); do
    ok=1
    for ((i=0; i<tab_count; i++)); do
        [[ -n "${konsole_exists[$(( ${tab_tid[i]} + k ))]:-}" ]] || { ok=0; break; }
    done
    if (( ok )); then offset="$k"; break; fi
done

if [[ -z "$offset" ]]; then
    echo "Warning: could not map tabs to Konsole sessions; keeping previous session.json" >&2
    exit 0
fi

tabs_json="[]"

for ((i=0; i<tab_count; i++)); do
    konsole_sid=$(( ${tab_tid[i]} + offset ))

    # Working directory of the tab's shell. Konsole exposes processId but not
    # currentWorkingDirectory on these embedded sessions, so read it from /proc.
    pid=$(qdbus org.kde.yakuake "/Sessions/$konsole_sid" processId 2>/dev/null || echo "")
    cwd="$HOME"
    if [[ -n "$pid" ]] && [[ -d "/proc/$pid/cwd" ]]; then
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "$HOME")
    fi

    tabs_json=$(echo "$tabs_json" | jq \
        --argjson idx "$i" \
        --arg title "${tab_title[i]}" \
        --arg cwd "$cwd" \
        '. + [{
            "index": $idx,
            "title": $title,
            "cwd": $cwd
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
        "version": 3,
        "saved_at": $timestamp,
        "tabs": $tabs
    }' > "$STATE_FILE"

echo "Saved $tab_count tabs to $STATE_FILE"
