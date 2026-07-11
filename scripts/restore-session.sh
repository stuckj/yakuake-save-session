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

# qdbus (Qt 6.11 / qttools) segfaults in its atexit handler AFTER it has
# already produced correct output (QMetaType::unregisterMetaType, reached via
# registerComplexDBusType's hash destructor during exit()). The D-Bus call
# itself succeeds; only the teardown crashes, so the process exits via SIGSEGV
# (status >= 128) and dumps core. Wrap it to (a) disable the core dump and
# (b) treat a signal-kill as success so `set -e` doesn't abort restore on a
# crash that happened after the work was done.
_QDBUS_BIN="$(type -P qdbus || true)"
qdbus() {
    local out rc
    out="$(ulimit -c 0; "$_QDBUS_BIN" "$@" 2>/dev/null)"
    rc=$?
    [[ -n "$out" ]] && printf '%s\n' "$out"
    (( rc >= 128 )) && return 0
    return "$rc"
}

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
    # Match Ubuntu's "yakuake" or NixOS's truncated ".yakuake-wrappe"
    if pgrep -x 'yakuake|\.yakuake-wrappe' &>/dev/null && qdbus org.kde.yakuake /yakuake/sessions sessionIdList &>/dev/null; then
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "Timed out waiting for Yakuake" >&2
        cleanup
        exit 1
    fi
    sleep 1
done

saved_tab_count=$(jq '.tabs | length' "$STATE_FILE")
echo "Restoring session ($saved_tab_count saved tab(s))..."

# --- Restore tmux sessions if needed ---
if tmux list-sessions &>/dev/null 2>&1; then
    echo "tmux server is running, will reattach to existing sessions"
else
    echo "tmux server is not running, starting and restoring sessions..."

    # Fix broken resurrect 'last' symlink before attempting restore.
    # The symlink can break if a save is interrupted (e.g., by sudden shutdown).
    RESURRECT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
    RESURRECT_LAST="$RESURRECT_DIR/last"
    if [[ -L "$RESURRECT_LAST" ]] && [[ ! -e "$RESURRECT_LAST" ]]; then
        echo "Fixing broken resurrect 'last' symlink..."
        latest=$(ls -1t "$RESURRECT_DIR"/tmux_resurrect_*.txt 2>/dev/null | head -1)
        if [[ -n "$latest" ]]; then
            ln -sf "$(basename "$latest")" "$RESURRECT_LAST"
            echo "Pointed 'last' to $(basename "$latest")"
        fi
    fi

    # Start a temporary tmux session to bootstrap the server.
    # This loads ~/.tmux.conf (which sources our tmux.conf), initializing TPM
    # and setting resurrect options.
    tmux new-session -d -s _yakuake_bootstrap

    # Give TPM a moment to initialize
    sleep 2

    # Explicitly run tmux-resurrect restore
    if [[ -x "$RESURRECT_RESTORE" ]]; then
        tmux run-shell "$RESURRECT_RESTORE" 2>&1 || echo "Warning: resurrect restore failed" >&2
        # Give resurrect time to recreate sessions (large configs need more time)
        sleep 5
    else
        echo "Warning: tmux-resurrect restore script not found at $RESURRECT_RESTORE" >&2
    fi

    # Clean up bootstrap session
    tmux kill-session -t _yakuake_bootstrap 2>/dev/null || true
fi

# --- Build the ordered list of tabs to create ---
# Union of saved tabs and every tmux session that resurrect actually restored,
# so no restored scrollback buffer is ever left without a tab (an untabbed
# session would eventually be reaped as an orphan, losing its scrollback).
# Saved tabs come first, preserving their title/order; any restored session not
# referenced by a saved tab is appended with a generic title.
declare -a entry_title=() entry_cwd=() entry_tmux=()
declare -A saved_sessions=()

while IFS=$'\t' read -r e_tmux e_title e_cwd; do
    # A saved tab with no tmux session (rare raw-shell tab) gets a fresh name
    # so the profile script creates a new session for it rather than colliding.
    [[ -z "$e_tmux" ]] && e_tmux="yakuake-fresh-${RANDOM}"
    entry_tmux+=("$e_tmux")
    entry_title+=("$e_title")
    entry_cwd+=("$e_cwd")
    saved_sessions["$e_tmux"]=1
done < <(jq -r '.tabs[] | [.tmux_session // "", .title // "", .cwd // ""] | @tsv' "$STATE_FILE")

# Append restored tmux sessions that no saved tab references.
while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    [[ "$s" != yakuake-* ]] && continue
    [[ -n "${saved_sessions[$s]:-}" ]] && continue
    echo "Restored session '$s' had no saved tab; adding one to preserve its scrollback" >&2
    entry_tmux+=("$s")
    entry_title+=("$s")
    s_cwd=$(tmux display-message -t "$s" -p '#{pane_current_path}' 2>/dev/null || echo "$HOME")
    entry_cwd+=("$s_cwd")
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

tab_count=${#entry_tmux[@]}

if [[ "$tab_count" -eq 0 ]]; then
    echo "No tabs or sessions to restore" >&2
    cleanup
    exit 0
fi

echo "Creating $tab_count tab(s)..."

# --- Create tabs and write instruction files ---
mkdir -p "$INSTRUCTION_DIR"
chmod 700 "$INSTRUCTION_DIR"

# Helper: list Konsole session IDs (numbers from /Sessions/N)
list_konsole_sids() {
    qdbus org.kde.yakuake 2>/dev/null | grep -E '^/Sessions/[0-9]+$' | sed 's|/Sessions/||' | sort -n
}

# Helper: find a new Konsole session ID (not in $1) by polling for up to 5s
find_new_konsole_sid() {
    local before="$1"
    for _ in $(seq 1 50); do
        local current
        current=$(list_konsole_sids)
        for sid in $current; do
            if ! echo "$before" | grep -qE "^$sid$"; then
                echo "$sid"
                return 0
            fi
        done
        sleep 0.1
    done
    return 1
}

default_session=$(qdbus org.kde.yakuake /yakuake/sessions sessionIdList | cut -d, -f1)

# Pre-write instruction files for predictable Konsole session numbers.
# After a reboot, Yakuake starts fresh and Konsole session IDs begin at 1.
# The default tab gets Konsole session 1, and each addSession gets the next
# number (2, 3, 4, ...). Writing these BEFORE creating tabs eliminates the
# race condition where the profile script times out before the instruction
# file is written.
#
# We still detect the actual IDs after creating tabs and write corrections
# if they differ from predictions. The profile script in tmux-auto-session.sh
# will find the correct file regardless.
pre_first_konsole_sid=1
for ((i = 0; i < tab_count; i++)); do
    pre_konsole_sid=$((pre_first_konsole_sid + i))
    echo "${entry_tmux[$i]}" > "$INSTRUCTION_DIR/$pre_konsole_sid"
done

# Snapshot initial Konsole sessions — for the default tab (tab 0), the
# only existing Konsole session belongs to it.
initial_konsole_sids=$(list_konsole_sids)
default_konsole_sid=$(echo "$initial_konsole_sids" | head -1)

for ((i = 0; i < tab_count; i++)); do
    title="${entry_title[$i]}"
    cwd="${entry_cwd[$i]}"
    tmux_name="${entry_tmux[$i]}"

    # First tab: reuse the existing default session. Otherwise: add a new one
    # and detect which Konsole session path was created for it.
    if [[ $i -eq 0 ]]; then
        session_id="$default_session"
        konsole_sid="$default_konsole_sid"
    else
        before_sids=$(list_konsole_sids)
        session_id=$(qdbus org.kde.yakuake /yakuake/sessions addSession)
        konsole_sid=$(find_new_konsole_sid "$before_sids" || true)
        if [[ -z "$konsole_sid" ]]; then
            echo "Warning: could not detect Konsole session for tab $i (yakuake sid=$session_id)" >&2
            # Fall back: assume sequential IDs after the first
            konsole_sid=$((pre_first_konsole_sid + i))
        fi
    fi

    # Set tab title
    qdbus org.kde.yakuake /yakuake/tabs org.kde.yakuake.setTabTitle "$session_id" "$title" 2>/dev/null

    # Attach this tab to its saved tmux session by NAME. resurrect restores
    # sessions under their original names, so scrollback is preserved and the
    # title (set above) travels with the correct content. If the named session
    # is missing (e.g. the resurrect save was interrupted), create it with the
    # saved cwd so the tab is never blank. When it exists the profile script
    # attaches to it via `tmux new-session -A`.
    if ! tmux has-session -t "$tmux_name" 2>/dev/null; then
        echo "Warning: saved session '$tmux_name' not restored; creating it fresh at $cwd" >&2
        tmux new-session -d -s "$tmux_name" -c "$cwd" 2>/dev/null || true
    fi

    echo "$tmux_name" > "$INSTRUCTION_DIR/$konsole_sid"
done

# Raise the first tab
first_session=$(qdbus org.kde.yakuake /yakuake/sessions sessionIdList | cut -d, -f1)
qdbus org.kde.yakuake /yakuake/sessions raiseSession "$first_session"

echo "Restored $tab_count tabs"

# Wait for profile scripts to consume instruction files, then clean up.
# The 5-second wait gives even slow systems time to start Konsole sessions
# and run the profile command. Any remaining instruction files are stale.
sleep 5
cleanup
