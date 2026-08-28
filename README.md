# yakuake-save-session

Save and restore [Yakuake](https://apps.kde.org/yakuake/) tab names, visual order, and working directories across reboots and logouts.

## What it does

- **Saves** Yakuake tab names, visual order, and working directories via D-Bus
- **Restores** those tabs on login, in order, each `cd`'d to its saved directory
- **Nothing else.** Tabs are plain shells.

### What it deliberately does not do

It does not persist scrollback, and it does not manage terminal multiplexers.

Earlier versions ran a tmux session per tab and tried to keep Yakuake tab
indices, Konsole terminal IDs, and tmux session names in agreement. None of
those three ID spaces is authoritative and Yakuake assigns them during a racy
startup, so the mapping broke in a new way roughly every time the timing
shifted — content landing on the wrong tab, or not at all.

If you want scrollback that survives a reboot, let tmux own that directly:

```tmux
set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'on'
set -g @continuum-save-interval '5'
```

Then run `tmux` in whichever tabs you want it, and attach from any terminal.
Sessions are yours to name. This project stays out of it.

## How it works

| Trigger | What happens |
|---------|-------------|
| **Login** | KDE autostart runs the wrapper, which waits for a display, starts Yakuake, and restores tabs |
| **Every 5 min** | Systemd timer saves the tab layout |
| **Logout/shutdown** | Systemd service saves the layout before session teardown |

The wrapper waits up to 5 minutes for a usable display before starting Yakuake,
and gives up rather than starting without one. Launching Yakuake with no Wayland
compositor is not a slow start — it is a hard Qt abort that repeats until
something intervenes.

## Dependencies

- [Yakuake](https://apps.kde.org/yakuake/) (KDE drop-down terminal)
- [jq](https://jqlang.github.io/jq/)
- `qdbus` and `busctl`
- systemd (user session)

## Installation

```bash
git clone https://github.com/stuckj/yakuake-save-session.git
cd yakuake-save-session
bash scripts/install.sh
```

The installer will:
1. Symlink scripts to `~/.local/bin/`
2. Back up and replace the Yakuake autostart entry
3. Generate systemd user units for periodic and shutdown saves
4. Remove the tmux Konsole profile left by earlier versions, if present
5. Save your current Yakuake session

## File layout

```
scripts/
├── install.sh              # One-time setup (idempotent, safe to re-run)
├── save-session.sh         # Captures tab state to JSON
├── restore-session.sh      # Recreates tabs, titles and directories
└── yakuake-wrapper.sh      # Autostart entrypoint: starts Yakuake + restores
```

Session state is saved to `~/.local/share/yakuake-session/session.json` with rotating backups.

## Uninstallation

```bash
systemctl --user disable --now yakuake-session-autosave.timer
systemctl --user disable --now yakuake-session-shutdown.service
rm -f ~/.local/bin/yakuake-session-{save,restore,wrapper}
rm -f ~/.config/autostart/yakuake-session.desktop
rm -f ~/.config/systemd/user/yakuake-session-{autosave.service,autosave.timer,shutdown.service}
```

Then restore the original Yakuake autostart: remove `Hidden=true` from
`~/.config/autostart/org.kde.yakuake.desktop`, or restore it from `.bak`.

## Notes

- The save script keeps the last 10 backups in `~/.local/share/yakuake-session/backups/`
- Working directories are read from `/proc/<pid>/cwd`, because Konsole does not
  expose `currentWorkingDirectory` on Yakuake's embedded sessions
- Restore applies a directory by sending `cd` via `runCommandInTerminal`, which
  D-Bus restricts to your own user session

## License

MIT
