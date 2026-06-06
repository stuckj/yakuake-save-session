#!/usr/bin/env bash
# Wrapper script for Yakuake that handles session restore on startup.
# Intended to replace Yakuake's autostart entry.
#
# Session saving is handled separately by:
#   - systemd timer (periodic autosave every 5 min)
#   - systemd shutdown service (saves before session teardown)

set -euo pipefail

# Resolve the restore script relative to this script's location.
# Works whether run from the repo or via a symlink in ~/.local/bin.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
RESTORE_SCRIPT="$SCRIPT_DIR/restore-session.sh"

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yakuake-session"
FLAG_FILE="$STATE_DIR/restore-in-progress"
INSTRUCTION_DIR="$STATE_DIR/tab-instructions"

yakuake_process_running() {
    # Match Ubuntu's "yakuake" or NixOS's truncated ".yakuake-wrappe"
    # (Linux truncates /proc/PID/comm to 15 chars; NixOS wraps binaries
    # as ".NAME-wrapped").
    pgrep -x 'yakuake|\.yakuake-wrappe' &>/dev/null
}

yakuake_dbus_ready() {
    qdbus org.kde.yakuake /yakuake/sessions sessionIdList &>/dev/null
}

start_yakuake() {
    echo "Starting Yakuake..."
    yakuake &
    disown

    # Wait for it to register on D-Bus
    for i in $(seq 1 30); do
        if yakuake_dbus_ready; then
            echo "Yakuake is ready on D-Bus"
            return 0
        fi
        sleep 1
    done

    echo "Timed out waiting for Yakuake to start" >&2
    return 1
}

wait_for_display() {
    # On Wayland environments (NixOS, etc.), the display may not be ready
    # when the autostart entry fires. Starting Yakuake before the display
    # is ready causes it to crash with "Could not load the Qt platform
    # plugin". Wait for the display to become available.
    for i in $(seq 1 30); do
        if [[ -n "${WAYLAND_DISPLAY:-}" ]] || [[ -n "${DISPLAY:-}" ]]; then
            # Wayland: check that the compositor socket exists
            if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
                local wayland_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY}"
                if [[ -S "$wayland_socket" ]] || [[ -n "${DISPLAY:-}" ]]; then
                    echo "Display is ready ($WAYLAND_DISPLAY)"
                    return 0
                fi
            elif [[ -n "${DISPLAY:-}" ]]; then
                echo "Display is ready ($DISPLAY)"
                return 0
            fi
        fi
        sleep 1
    done
    echo "Warning: display not detected after 30s, proceeding anyway" >&2
}

restore_session() {
    echo "Restoring Yakuake session..."
    "$RESTORE_SCRIPT" || echo "Warning: failed to restore session" >&2
}

# --- Main ---

# Use pgrep to check process, NOT D-Bus — querying D-Bus triggers
# auto-activation which restarts Yakuake via /usr/share/dbus-1/services/
if yakuake_process_running; then
    echo "Yakuake is already running, not restoring session"
    exit 0
fi

# Clean stale state from a previous restore that may have crashed
rm -f "$FLAG_FILE"
rm -rf "$INSTRUCTION_DIR"

# Wait for the display to be ready before starting Yakuake. Without this,
# Yakuake crashes repeatedly on Wayland systems where the compositor starts
# after autostart entries are processed.
wait_for_display

# Create the restore-in-progress flag BEFORE starting Yakuake.
# This tells the Konsole profile script (tmux-auto-session.sh) to wait
# for instruction files instead of auto-generating a tmux session name.
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
touch "$FLAG_FILE"

start_yakuake

# Small delay to let Yakuake fully initialize its default tab
sleep 1
restore_session
