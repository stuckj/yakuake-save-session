#!/usr/bin/env bash
# Install yakuake-save-session: symlinks scripts to ~/.local/bin, generates
# systemd units and autostart entry, installs tmux plugins.
#
# Safe to run multiple times (idempotent).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
AUTOSTART_DIR="$HOME/.config/autostart"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
TPM_DIR="$HOME/.tmux/plugins/tpm"

echo "=== yakuake-save-session installer ==="
echo "Project dir: $PROJECT_DIR"
echo ""

# --- Make scripts executable and symlink to ~/.local/bin ---
chmod +x "$PROJECT_DIR/scripts/"*.sh
mkdir -p "$BIN_DIR"

ln -sf "$PROJECT_DIR/scripts/save-session.sh" "$BIN_DIR/yakuake-session-save"
ln -sf "$PROJECT_DIR/scripts/restore-session.sh" "$BIN_DIR/yakuake-session-restore"
ln -sf "$PROJECT_DIR/scripts/yakuake-wrapper.sh" "$BIN_DIR/yakuake-session-wrapper"
ln -sf "$PROJECT_DIR/scripts/tmux-auto-session.sh" "$BIN_DIR/yakuake-session-tmux"
echo "[ok] Scripts symlinked to $BIN_DIR"

# --- Back up and replace Yakuake autostart ---
mkdir -p "$AUTOSTART_DIR"

ORIGINAL_AUTOSTART="$AUTOSTART_DIR/org.kde.yakuake.desktop"
BACKUP_AUTOSTART="$AUTOSTART_DIR/org.kde.yakuake.desktop.bak"
NEW_AUTOSTART="$AUTOSTART_DIR/yakuake-session.desktop"

if [[ -f "$ORIGINAL_AUTOSTART" ]] && [[ ! -f "$BACKUP_AUTOSTART" ]]; then
    cp "$ORIGINAL_AUTOSTART" "$BACKUP_AUTOSTART"
    echo "[ok] Backed up original autostart to $BACKUP_AUTOSTART"
fi

# Disable the original autostart (KDE reads all .desktop files in the dir)
if [[ -f "$ORIGINAL_AUTOSTART" ]]; then
    if ! grep -q '^Hidden=true' "$ORIGINAL_AUTOSTART"; then
        echo "Hidden=true" >> "$ORIGINAL_AUTOSTART"
        echo "[ok] Disabled original Yakuake autostart (Hidden=true)"
    else
        echo "[ok] Original Yakuake autostart already disabled"
    fi
fi

# Generate autostart entry (no hardcoded paths in the repo)
cat > "$NEW_AUTOSTART" <<EOF
[Desktop Entry]
Categories=Qt;KDE;System;TerminalEmulator;
Comment=Yakuake with session save/restore
Exec=$BIN_DIR/yakuake-session-wrapper
GenericName=Drop-down Terminal
Icon=yakuake
Name=Yakuake (Session Manager)
Terminal=false
Type=Application
X-KDE-StartupNotify=false
X-GNOME-Autostart-enabled=true
EOF
echo "[ok] Generated autostart entry at $NEW_AUTOSTART"

# --- Generate and install systemd units ---
mkdir -p "$SYSTEMD_USER_DIR"

cat > "$SYSTEMD_USER_DIR/yakuake-session-autosave.service" <<EOF
[Unit]
Description=Auto-save Yakuake session state (tab layout)

[Service]
Type=oneshot
ExecStart=$BIN_DIR/yakuake-session-save
EOF

cat > "$SYSTEMD_USER_DIR/yakuake-session-autosave.timer" <<EOF
[Unit]
Description=Periodically save Yakuake session state

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

cat > "$SYSTEMD_USER_DIR/yakuake-session-shutdown.service" <<EOF
[Unit]
Description=Save Yakuake session state before shutdown
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=$BIN_DIR/yakuake-session-save

[Install]
WantedBy=graphical-session.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now yakuake-session-autosave.timer
echo "[ok] Enabled systemd autosave timer"
systemctl --user enable --now yakuake-session-shutdown.service
echo "[ok] Enabled systemd shutdown save service"

# --- Set up Konsole profile for Yakuake ---
KONSOLE_PROFILE_DIR="$HOME/.local/share/konsole"
KONSOLE_PROFILE="$KONSOLE_PROFILE_DIR/Yakuake Tmux.profile"
mkdir -p "$KONSOLE_PROFILE_DIR"

cat > "$KONSOLE_PROFILE" <<EOF
[General]
Command=$BIN_DIR/yakuake-session-tmux
Name=Yakuake Tmux
Parent=FALLBACK/

[Scrolling]
HistoryMode=2
EOF
echo "[ok] Generated Konsole profile at $KONSOLE_PROFILE"

# Point Yakuake at the new profile
YAKUAKERC="$HOME/.config/yakuakerc"
if [[ -f "$YAKUAKERC" ]]; then
    if grep -q '^DefaultProfile=' "$YAKUAKERC"; then
        sed -i 's/^DefaultProfile=.*/DefaultProfile=Yakuake Tmux.profile/' "$YAKUAKERC"
    else
        sed -i '/^\[Desktop Entry\]/a DefaultProfile=Yakuake Tmux.profile' "$YAKUAKERC"
    fi
else
    mkdir -p "$(dirname "$YAKUAKERC")"
    cat > "$YAKUAKERC" <<EOF
[Desktop Entry]
DefaultProfile=Yakuake Tmux.profile
EOF
fi
echo "[ok] Yakuake configured to use Yakuake Tmux profile"

# --- Install tmux plugin manager (if not present) ---
if [[ ! -d "$TPM_DIR" ]]; then
    echo "Installing tmux plugin manager (TPM)..."
    git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
    echo "[ok] TPM installed"
else
    echo "[ok] TPM already installed"
fi

# --- Set up tmux config ---
TMUX_CONF="$HOME/.tmux.conf"
SOURCE_LINE="source-file $PROJECT_DIR/tmux.conf"

if [[ -f "$TMUX_CONF" ]]; then
    if ! grep -qF "$SOURCE_LINE" "$TMUX_CONF"; then
        echo "" >> "$TMUX_CONF"
        echo "# yakuake-save-session tmux config" >> "$TMUX_CONF"
        echo "$SOURCE_LINE" >> "$TMUX_CONF"
        echo "[ok] Added source-file line to existing $TMUX_CONF"
    else
        echo "[ok] $TMUX_CONF already sources our config"
    fi
else
    echo "$SOURCE_LINE" > "$TMUX_CONF"
    echo "[ok] Created $TMUX_CONF"
fi

# --- Install tmux plugins directly (doesn't require a running tmux server) ---
PLUGIN_DIR="$HOME/.tmux/plugins"
for plugin in tmux-resurrect tmux-continuum; do
    if [[ ! -d "$PLUGIN_DIR/$plugin" ]]; then
        git clone "https://github.com/tmux-plugins/$plugin" "$PLUGIN_DIR/$plugin"
        echo "[ok] Installed $plugin"
    else
        echo "[ok] $plugin already installed"
    fi
done

# --- Initial save of current session ---
echo ""
echo "Running initial session save..."
"$BIN_DIR/yakuake-session-save" || echo "[warn] Initial save failed (is Yakuake running?)"

echo ""
echo "=== Installation complete ==="
echo ""
echo "What happens now:"
echo "  - Your current Yakuake tabs have been saved"
echo "  - Tab layout is auto-saved every 5 minutes (systemd timer)"
echo "  - Tab layout is saved on logout/shutdown (systemd shutdown service)"
echo "  - On next login, the wrapper script will start Yakuake and restore tabs"
echo "  - Each tab will run inside a named tmux session for scrollback persistence"
echo "  - tmux state (directories, scrollback) auto-saves every 10 minutes"
echo ""
echo "To uninstall:"
echo "  systemctl --user disable --now yakuake-session-autosave.timer"
echo "  systemctl --user disable --now yakuake-session-shutdown.service"
echo "  rm -f $BIN_DIR/yakuake-session-{save,restore,wrapper,tmux}"
echo "  rm -f $NEW_AUTOSTART"
echo "  rm -f $SYSTEMD_USER_DIR/yakuake-session-{autosave.service,autosave.timer,shutdown.service}"
echo "  rm -f '$KONSOLE_PROFILE'"
echo "  Restore $ORIGINAL_AUTOSTART from .bak"
echo "  Set DefaultProfile back in $YAKUAKERC"
echo "  Remove source-file line from $TMUX_CONF"
