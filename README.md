# yakuake-save-session

Save and restore [Yakuake](https://apps.kde.org/yakuake/) terminal sessions across reboots and logouts, including tab names, order, working directories, and scrollback history.

Similar to how iTerm2 handles session persistence on macOS.

## What it does

- **Saves** Yakuake tab names, visual order, and working directories via D-Bus
- **Restores** tabs on login with correct names and directories
- **Preserves scrollback history** across reboots using [tmux](https://github.com/tmux/tmux) with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum)
- **Survives logout/login** without losing any state (tmux sessions stay alive)
- **New tabs** automatically get tmux via a Konsole profile

## How it works

| Trigger | What happens |
|---------|-------------|
| **Login** | KDE autostart runs the wrapper script, which starts Yakuake, restores tabs, and attaches each to a named tmux session |
| **Every 5 min** | Systemd timer saves Yakuake tab layout; tmux-continuum saves tmux state (scrollback) every 10 min |
| **Logout/shutdown** | Systemd service saves tab layout before session teardown |
| **Logout/login (no reboot)** | tmux sessions survive; tabs reattach to existing sessions with full state |
| **Reboot** | tmux-resurrect restores sessions from disk (directories + scrollback) |
| **New manual tab** | Konsole profile auto-starts tmux with the next available session name |

## Dependencies

- [Yakuake](https://apps.kde.org/yakuake/) (KDE drop-down terminal)
- [tmux](https://github.com/tmux/tmux)
- [jq](https://jqlang.github.io/jq/)
- `qdbus` (part of Qt/KDE tools)
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
4. Create a Konsole profile that auto-starts tmux in new tabs
5. Install tmux plugin manager (TPM) and plugins (tmux-resurrect, tmux-continuum)
6. Add a `source-file` line to `~/.tmux.conf`
7. Save your current Yakuake session

## File layout

```
scripts/
├── install.sh              # One-time setup (idempotent, safe to re-run)
├── save-session.sh         # Captures tab state to JSON
├── restore-session.sh      # Recreates tabs and coordinates tmux attachment
├── yakuake-wrapper.sh      # Autostart entrypoint: starts Yakuake + restores
└── tmux-auto-session.sh    # Konsole profile command: manages tmux sessions
tmux.conf                   # tmux config (resurrect + continuum)
```

Session state is saved to `~/.local/share/yakuake-session/session.json` with rotating backups.

## Uninstallation

```bash
systemctl --user disable --now yakuake-session-autosave.timer
systemctl --user disable --now yakuake-session-shutdown.service
rm -f ~/.local/bin/yakuake-session-{save,restore,wrapper,tmux}
rm -f ~/.config/autostart/yakuake-session.desktop
rm -f ~/.config/systemd/user/yakuake-session-{autosave.service,autosave.timer,shutdown.service}
rm -f ~/.local/share/konsole/Yakuake\ Tmux.profile
```

Then restore the original Yakuake autostart:
- Remove `Hidden=true` from `~/.config/autostart/org.kde.yakuake.desktop` (or restore from `.bak`)
- Set `DefaultProfile` back to your original profile in `~/.config/yakuakerc`
- Remove the `source-file` line from `~/.tmux.conf`

## Notes

- The save script keeps the last 10 backups in `~/.local/share/yakuake-session/backups/`
- The restore script uses `runCommandInTerminal` via D-Bus, which is restricted to your user session
- Scroll up in tmux with `Ctrl-b` then `[`, navigate with arrow keys/Page Up/Down, press `q` to exit

## License

MIT
