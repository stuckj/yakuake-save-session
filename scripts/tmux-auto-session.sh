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

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yakuake-session"
INSTRUCTION_DIR="$STATE_DIR/tab-instructions"
FLAG_FILE="$STATE_DIR/restore-in-progress"

# During restore: wait for an instruction file telling us which tmux session to attach to
if [[ -f "$FLAG_FILE" ]]; then
    # Extract Konsole session number from KONSOLE_DBUS_SESSION (format: /Sessions/N)
    if [[ "${KONSOLE_DBUS_SESSION:-}" =~ /Sessions/([0-9]+) ]]; then
        konsole_id="${BASH_REMATCH[1]}"
        instruction_file="$INSTRUCTION_DIR/$konsole_id"

        # Poll for instruction file (up to 15 seconds)
        for i in $(seq 1 75); do
            if [[ -f "$instruction_file" ]]; then
                session_name=$(cat "$instruction_file")
                rm -f "$instruction_file"
                exec tmux new-session -A -s "$session_name"
            fi
            sleep 0.2
        done
    fi
    # Timeout or no KONSOLE_DBUS_SESSION — fall through to auto-generate
fi

# Manual tab: find the next available yakuake-N session name
n=0
while tmux has-session -t "yakuake-$n" 2>/dev/null; do
    n=$((n + 1))
done

exec tmux new-session -s "yakuake-$n"
