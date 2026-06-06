#!/usr/bin/env bash
# Konsole profile command: start or attach to a tmux session.
#
# During a Yakuake session restore, the restore script creates a
# "restore-in-progress" flag and writes per-tab instruction files
# keyed by Konsole D-Bus session ID. This script waits for its
# instruction file and attaches to the specified tmux session.
#
# For manually opened tabs (no restore in progress), it auto-generates
# the next available yakuake-N session name.
#
# Fallback: if the instruction file is not found within the timeout,
# the script tries to attach to a resurrected session by tab index
# before falling through to creating a brand-new session.

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yakuake-session"
INSTRUCTION_DIR="$STATE_DIR/tab-instructions"
FLAG_FILE="$STATE_DIR/restore-in-progress"

# During restore: wait for an instruction file telling us which tmux session to attach to
if [[ -f "$FLAG_FILE" ]]; then
    # Extract Konsole session number from KONSOLE_DBUS_SESSION (format: /Sessions/N)
    if [[ "${KONSOLE_DBUS_SESSION:-}" =~ /Sessions/([0-9]+) ]]; then
        konsole_id="${BASH_REMATCH[1]}"
        instruction_file="$INSTRUCTION_DIR/$konsole_id"

        # Poll for instruction file (up to 120 seconds). The restore process
        # can take 25+ seconds on reboot (tmux-resurrect + tab creation),
        # and Yakuake may crash-restart if the display isn't ready yet, adding
        # further delay. 120s gives ample margin.
        for i in $(seq 1 600); do
            if [[ -f "$instruction_file" ]]; then
                session_name=$(cat "$instruction_file")
                rm -f "$instruction_file"
                exec tmux new-session -A -s "$session_name"
            fi
            sleep 0.2
        done

        # Timeout: instruction file not found. Try to attach to a resurrected
        # session by tab index. The restore script creates tabs in order 0..N,
        # and resurrected sessions are named yakuake-0..yakuake-N. If our
        # Konsole session ID is K, our tab index is roughly (K - 1) for the
        # default tab being index 0. Try that session first.
        tab_idx=$((konsole_id - 1))
        if (( tab_idx >= 0 )) && tmux has-session -t "yakuake-${tab_idx}" 2>/dev/null; then
            echo "Warning: instruction file timeout, attaching to resurrected session yakuake-${tab_idx}" >&2
            exec tmux new-session -A -s "yakuake-${tab_idx}"
        fi
    fi
    # Timeout or no KONSOLE_DBUS_SESSION — fall through to auto-generate
fi

# Manual tab: find the next available yakuake-N session name
n=0
while tmux has-session -t "yakuake-$n" 2>/dev/null; do
    n=$((n + 1))
done

exec tmux new-session -s "yakuake-$n"