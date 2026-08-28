#!/usr/bin/env bash
# Restore Yakuake tabs (names, order, working directories) from saved state.
# Expects Yakuake to already be running on D-Bus.

set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yakuake-session"
STATE_FILE="$STATE_DIR/session.json"

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

if [[ ! -f "$STATE_FILE" ]]; then
    echo "No saved session found at $STATE_FILE" >&2
    exit 0
fi

# Wait for Yakuake process and D-Bus to be available (up to 30 seconds).
# Matches Ubuntu's "yakuake" and NixOS's truncated ".yakuake-wrappe".
for i in $(seq 1 30); do
    if pgrep -x 'yakuake|\.yakuake-wrappe' &>/dev/null \
       && qdbus org.kde.yakuake /yakuake/sessions sessionIdList &>/dev/null; then
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "Timed out waiting for Yakuake" >&2
        exit 1
    fi
    sleep 1
done

tab_count=$(jq '.tabs | length' "$STATE_FILE")

if [[ "$tab_count" -eq 0 ]]; then
    echo "No tabs to restore" >&2
    exit 0
fi

echo "Restoring $tab_count tab(s)..."

default_session=$(qdbus org.kde.yakuake /yakuake/sessions sessionIdList | cut -d, -f1)

for ((i = 0; i < tab_count; i++)); do
    title=$(jq -r ".tabs[$i].title // \"\"" "$STATE_FILE")
    cwd=$(jq -r ".tabs[$i].cwd // \"$HOME\"" "$STATE_FILE")

    # First tab reuses the one Yakuake already opened; the rest are added.
    if [[ $i -eq 0 ]]; then
        session_id="$default_session"
    else
        session_id=$(qdbus org.kde.yakuake /yakuake/sessions addSession)
    fi

    qdbus org.kde.yakuake /yakuake/tabs org.kde.yakuake.setTabTitle "$session_id" "$title" 2>/dev/null || true

    # Put the shell in its saved directory. There is no D-Bus call to set a
    # session's cwd, so send a cd into the terminal itself. printf %q quotes
    # paths containing spaces or shell metacharacters.
    if [[ -n "$cwd" && -d "$cwd" ]]; then
        terminal_id=$(qdbus org.kde.yakuake /yakuake/sessions terminalIdsForSessionId "$session_id" 2>/dev/null | cut -d, -f1)
        if [[ -n "$terminal_id" ]]; then
            printf -v cd_cmd 'cd %q' "$cwd"
            qdbus org.kde.yakuake /yakuake/sessions runCommandInTerminal "$terminal_id" "$cd_cmd" 2>/dev/null || true
        fi
    fi
done

# Raise the first tab
first_session=$(qdbus org.kde.yakuake /yakuake/sessions sessionIdList | cut -d, -f1)
qdbus org.kde.yakuake /yakuake/sessions raiseSession "$first_session" 2>/dev/null || true

echo "Restored $tab_count tabs"
