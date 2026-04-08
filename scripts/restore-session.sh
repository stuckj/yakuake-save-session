#!/usr/bin/env bash
# Restore Yakuake session from saved state.
# Expects Yakuake to already be running on D-Bus.
#
# Coordinates with tmux-auto-session.sh (the Konsole profile command) via
# instruction files. The wrapper script creates the restore-in-progress flag
# before starting Yakuake, so the profile script knows to wait.

set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yakuake-session"
STATE_FILE="$STATE_DIR/session.json"
INSTRUCTION_DIR="$STATE_DIR/tab-instructions"
FLAG_FILE="$STATE_DIR/restore-in-progress"
RESURRECT_RESTORE="$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh"

cleanup() {
    rm -f "$FLAG_FILE"
    rm -rf "$INSTRUCTION_DIR"
}

if [[ ! -f "$STATE_FILE" ]]; then
    echo "No saved session found at $STATE_FILE" >&2
    cleanup
    exit 0
fi

# Wait for Yakuake process and D-Bus to be available (up to 30 seconds)
for i in $(seq 1 30); do
    if pgrep -x yakuake &>/dev/null && qdbus org.kde.yakuake /yakuake/sessions sessionIdList &>/dev/null; then
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "Timed out waiting for Yakuake" >&2
        cleanup
        exit 1
    fi
    sleep 1
done

tab_count=$(jq '.tabs | length' "$STATE_FILE")

if [[ "$tab_count" -eq 0 ]]; then
    echo "No tabs to restore" >&2
    cleanup
    exit 0
fi

echo "Restoring $tab_count tabs..."

# --- Restore tmux sessions if needed ---
if tmux list-sessions &>/dev/null 2>&1; then
    echo "tmux server is running, will reattach to existing sessions"
else
    echo "tmux server is not running, starting and restoring sessions..."
    # Start a temporary tmux session to bootstrap the server.
    # This loads ~/.tmux.conf (which sources our tmux.conf), initializing TPM
    # and setting resurrect options.
    tmux new-session -d -s _yakuake_bootstrap

    # Give TPM a moment to initialize
    sleep 1

    # Explicitly run tmux-resurrect restore
    if [[ -x "$RESURRECT_RESTORE" ]]; then
        tmux run-shell "$RESURRECT_RESTORE" 2>/dev/null || echo "Warning: resurrect restore failed" >&2
        # Give resurrect time to recreate sessions
        sleep 2
    else
        echo "Warning: tmux-resurrect restore script not found at $RESURRECT_RESTORE" >&2
    fi

    # Clean up bootstrap session
    tmux kill-session -t _yakuake_bootstrap 2>/dev/null || true
fi

# --- Create tabs and write instruction files ---
mkdir -p "$INSTRUCTION_DIR"
chmod 700 "$INSTRUCTION_DIR"

default_session=$(qdbus org.kde.yakuake /yakuake/sessions sessionIdList | cut -d, -f1)

for ((i = 0; i < tab_count; i++)); do
    title=$(jq -r ".tabs[$i].title" "$STATE_FILE")
    cwd=$(jq -r ".tabs[$i].cwd" "$STATE_FILE")

    # First tab: reuse the existing default session. Otherwise: add a new one.
    if [[ $i -eq 0 ]]; then
        session_id="$default_session"
    else
        session_id=$(qdbus org.kde.yakuake /yakuake/sessions addSession)
    fi

    # Set tab title
    qdbus org.kde.yakuake /yakuake/tabs org.kde.yakuake.setTabTitle "$session_id" "$title" 2>/dev/null

    # Compute the Konsole session ID (yakuake session ID + 1)
    konsole_sid=$((session_id + 1))

    # Write instruction file for tmux-auto-session.sh.
    # If the tmux session exists (reattach case), just use the name.
    # If it doesn't (reboot + resurrect restored it, or fresh), the profile
    # script will create it with -A (attach-or-create) and cd to the right dir.
    tmux_name="yakuake-${i}"

    # If the tmux session doesn't already exist, create it with the right directory
    if ! tmux has-session -t "$tmux_name" 2>/dev/null; then
        tmux new-session -d -s "$tmux_name" -c "$cwd" 2>/dev/null || true
    fi

    echo "$tmux_name" > "$INSTRUCTION_DIR/$konsole_sid"
done

# Raise the first tab
first_session=$(qdbus org.kde.yakuake /yakuake/sessions sessionIdList | cut -d, -f1)
qdbus org.kde.yakuake /yakuake/sessions raiseSession "$first_session"

echo "Restored $tab_count tabs"

# Wait for profile scripts to consume instruction files before cleanup
sleep 3
cleanup
