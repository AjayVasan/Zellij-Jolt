#!/usr/bin/env bash
# zellij-launcher installer
# Sets up the launcher script, optionally registers GNOME shortcuts,
# and shows Alacritty config instructions.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="zellij-launcher"
SOURCE="$REPO_DIR/$SCRIPT_NAME.sh"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zellij-launcher"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}╭──────────────────────────────────────────╮${NC}"
echo -e "${GREEN}│${NC}  ${YELLOW}zellij-launcher installer${NC}               ${GREEN}│${NC}"
echo -e "${GREEN}╰──────────────────────────────────────────╯${NC}"
echo ""

# ── Helpers ─────────────────────────────────────────────────────────

gsettings_set_shortcut() {
    local name="$1"
    local binding="$2"
    local command="$3"

    # Find the next available custom slot
    local existing
    existing=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")

    # Check if binding already exists
    local i=0
    while true; do
        local path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${i}/"
        if ! echo "$existing" | grep -q "$path"; then
            break
        fi
        # Check if this slot already has our binding
        local existing_binding
        existing_binding=$(gsettings get org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path" binding 2>/dev/null || echo "")
        if [[ "$existing_binding" == "'$binding'" ]]; then
            echo -e "${YELLOW}  Shortcut $binding is already registered — updating command.${NC}"
            gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path" name "$name"
            gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path" command "$command"
            return
        fi
        i=$((i + 1))
    done

    # Add new slot
    local new_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${i}/"

    # Add to list
    if [[ "$existing" == "@as []" ]]; then
        existing="['${new_path}']"
    else
        # Insert before closing bracket
        existing="${existing%]}, '${new_path}']"
    fi

    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$existing"
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$new_path" name "$name"
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$new_path" binding "$binding"
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$new_path" command "$command"
    echo -e "${GREEN}✓${NC} Registered $binding → $name"
}

# ── Check dependencies ──────────────────────────────────────────────
missing=()
for cmd in zellij fzf alacritty; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}Missing dependencies:${NC} ${missing[*]}"
    echo -e "${YELLOW}Install them first:${NC}"
    for m in "${missing[@]}"; do
        case "$m" in
            zellij)    echo "  sudo pacman -S zellij" ;;
            fzf)       echo "  sudo pacman -S fzf" ;;
            alacritty) echo "  sudo pacman -S alacritty" ;;
        esac
    done
    echo ""
    read -rp "Continue anyway? [y/N] " yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# ── Install script ──────────────────────────────────────────────────
echo -e "${CYAN}Installing ${SCRIPT_NAME}...${NC}"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

cp "$SOURCE" "${INSTALL_DIR}/${SCRIPT_NAME}.sh"
chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}.sh"

# Symlink into bin (overwrite if exists)
ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}.sh" "${BIN_DIR}/${SCRIPT_NAME}"

echo -e "${GREEN}✓${NC} Installed to ${INSTALL_DIR}/${SCRIPT_NAME}.sh"
echo -e "${GREEN}✓${NC} Symlinked at ${BIN_DIR}/${SCRIPT_NAME}"
echo ""

# Add to PATH if needed
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo -e "${YELLOW}Note:${NC} $BIN_DIR is not in your PATH."
    echo "Add this to your ~/.zshrc or ~/.bashrc:"
    echo -e "  ${CYAN}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
    echo ""
fi

# ── Configure Alacritty hook ────────────────────────────────────────
echo -e "${CYAN}Alacritty Integration${NC}"
echo ""
echo -e "${YELLOW}Option A:${NC} Launch zellij-launcher on every Alacritty open"
echo -e "  Add to ${CYAN}~/.config/alacritty/alacritty.toml${NC}:"
echo ""
echo -e "  ${CYAN}[terminal]${NC}"
echo -e "  ${CYAN}shell = \"${BIN_DIR}/zellij-launcher\"${NC}"
echo ""
echo -e "${YELLOW}Option B:${NC} Use keyboard shortcuts (recommended with installer)"
echo -e "  The installer can register Ctrl+Enter / Ctrl+Shift+Enter for you."
echo -e "  This way your normal terminals stay untouched."
echo ""

# ── Register GNOME shortcuts (optional) ─────────────────────────────
if [[ "$XDG_CURRENT_DESKTOP" == "GNOME" ]]; then
    echo -e "${CYAN}GNOME Keyboard Shortcuts${NC}"
    echo "Would you like to register these shortcuts?"
    echo ""
    echo "  1) Ctrl+Enter         → Alacritty → Zellij picker"
    echo "  2) Ctrl+Shift+Enter   → Alacritty → Zellij picker"
    echo "  3) Both (recommended)"
    echo "  n) No, skip"
    echo ""
    read -rp "Choose [1/2/3/n]: " choice

    case "$choice" in
        1)
            gsettings_set_shortcut \
                "zellij-launcher" \
                "<Control>Return" \
                "alacritty -e ${BIN_DIR}/zellij-launcher"
            ;;
        2)
            gsettings_set_shortcut \
                "zellij-launcher" \
                "<Control><Shift>Return" \
                "alacritty -e ${BIN_DIR}/zellij-launcher"
            ;;
        3|"")
            gsettings_set_shortcut \
                "zellij-launcher" \
                "<Control>Return" \
                "alacritty -e ${BIN_DIR}/zellij-launcher"
            gsettings_set_shortcut \
                "zellij-launcher-alt" \
                "<Control><Shift>Return" \
                "alacritty -e ${BIN_DIR}/zellij-launcher"
            ;;
        *)
            echo "Skipping shortcut registration."
            ;;
    esac
    echo ""
else
    echo -e "${YELLOW}Note:${NC} Non-GNOME desktop detected."
    echo "You'll need to register shortcuts manually for your WM/DE."
    echo ""
fi

# ── Done ────────────────────────────────────────────────────────────
echo -e "${GREEN}╭──────────────────────────────────────────╮${NC}"
echo -e "${GREEN}│${NC}  ${YELLOW}Installation complete!${NC}                     ${GREEN}│${NC}"
echo -e "${GREEN}╰──────────────────────────────────────────╯${NC}"
echo ""
echo -e "Run ${GREEN}zellij-launcher${NC} to start the session picker."
echo ""

# Show next steps
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Test it:             zellij-launcher"
echo "  2. Configure Alacritty: add [terminal] shell = ... to alacritty.toml"
echo "  3. Or just use shortcuts you registered above."
echo ""