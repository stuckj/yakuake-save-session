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

# How long to wait for a usable display before giving up. Generous on purpose:
# Plasma can take minutes to publish WAYLAND_DISPLAY after autostart fires, and
# starting Yakuake without a display is not a degraded start — it is a hard Qt
# abort ("could not load the Qt platform plugin") that repeats until something
# gives up. Waiting costs nothing; not waiting costs the session.
DISPLAY_WAIT_SECONDS=300

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
    # On Wayland environments (NixOS, etc.) the display is often not ready when
    # the XDG autostart entry fires. Worse, this service can start before Plasma
    # has populated WAYLAND_DISPLAY/DISPLAY into the systemd user environment, so
    # they may be missing from our *inherited* env entirely. When that happens
    # the original loop (which only checked our own env vars) timed out every
    # boot, and the Yakuake we then launched had no display and crashed with
    # "Could not load the Qt platform plugin", leaving restore to a flaky D-Bus
    # auto-activation race.
    #
    # Fix: actively import the display vars from the systemd user manager (and
    # fall back to probing for the Wayland socket directly), then EXPORT them so
    # the Yakuake we launch inherits a working display.
    local rundir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    for i in $(seq 1 "$DISPLAY_WAIT_SECONDS"); do
        # Import display vars from the systemd user manager if we don't have them.
        if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
            local line var val
            while IFS= read -r line; do
                var="${line%%=*}"; val="${line#*=}"
                case "$var" in
                    WAYLAND_DISPLAY|DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR)
                        export "$var=$val" ;;
                esac
            done < <(systemctl --user show-environment 2>/dev/null \
                       | grep -E '^(WAYLAND_DISPLAY|DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR)=')
            rundir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        fi

        # Fall back to probing for a live Wayland socket directly. The .lock
        # file is filtered out by the -S (socket) test.
        if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
            local sock
            for sock in "$rundir"/wayland-[0-9]*; do
                [[ -S "$sock" ]] || continue
                export WAYLAND_DISPLAY="${sock##*/}"
                break
            done
        fi

        if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
            if [[ -S "$rundir/$WAYLAND_DISPLAY" ]] || [[ -n "${DISPLAY:-}" ]]; then
                echo "Display is ready (WAYLAND_DISPLAY=$WAYLAND_DISPLAY)"
                return 0
            fi
        elif [[ -n "${DISPLAY:-}" ]]; then
            echo "Display is ready (DISPLAY=$DISPLAY)"
            return 0
        fi
        sleep 1
    done
    echo "No display after ${DISPLAY_WAIT_SECONDS}s; not starting Yakuake." >&2
    return 1
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

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Wait for the display before starting Yakuake. On Wayland the compositor is
# routinely not up when autostart entries fire, and launching without one is a
# crash loop rather than a slow start — so a failure here is a reason to stop,
# not to continue.
if ! wait_for_display; then
    exit 1
fi

start_yakuake

# Small delay to let Yakuake fully initialize its default tab
sleep 1
restore_session
