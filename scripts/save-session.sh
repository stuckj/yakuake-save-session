#!/usr/bin/env bash
# Save current Yakuake session state (tab names, order, working directories)
# to a JSON file that restore-session.sh can read.

set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yakuake-session"
STATE_FILE="$STATE_DIR/session.json"
BACKUP_DIR="$STATE_DIR/backups"
MAX_BACKUPS=10

mkdir -p "$STATE_DIR"

# Check that Yakuake process is actually running before querying D-Bus.
# (D-Bus auto-activation would restart Yakuake if we queried it while dead.)
if ! pgrep -x yakuake &>/dev/null; then
    echo "Yakuake is not running, nothing to save." >&2
    exit 1
fi

# Get tabs in visual order using sessionAtTab (sessionIdList is creation order, not tab order)
session_id_list=$(qdbus org.kde.yakuake /yakuake/sessions sessionIdList)
tab_count=$(echo "$session_id_list" | tr ',' '\n' | wc -l)

tabs_json="[]"
index=0

for ((i=0; i<tab_count; i++)); do
    sid=$(qdbus org.kde.yakuake /yakuake/tabs sessionAtTab "$i")

    title=$(qdbus org.kde.yakuake /yakuake/tabs tabTitle "$sid" 2>/dev/null || echo "")

    # Konsole session path is terminal_id + 1
    konsole_sid=$((sid + 1))
    pid=$(qdbus org.kde.yakuake /Sessions/$konsole_sid processId 2>/dev/null || echo "")
    cwd="$HOME"
    if [[ -n "$pid" ]] && [[ -d "/proc/$pid/cwd" ]]; then
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "$HOME")
    fi

    # Get terminal IDs for this session (for split pane support later)
    terminal_ids=$(qdbus org.kde.yakuake /yakuake/sessions terminalIdsForSessionId "$sid" 2>/dev/null || echo "$sid")

    tabs_json=$(echo "$tabs_json" | jq \
        --argjson idx "$index" \
        --arg title "$title" \
        --arg cwd "$cwd" \
        --arg sid "$sid" \
        --arg tids "$terminal_ids" \
        '. + [{
            "index": $idx,
            "session_id": ($sid | tonumber),
            "title": $title,
            "cwd": $cwd,
            "terminal_ids": $tids
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
