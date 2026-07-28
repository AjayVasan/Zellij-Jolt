#!/usr/bin/env bash
# zellij-jolt installer
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="zellij-jolt"
SOURCE="$REPO_DIR/$SCRIPT_NAME.sh"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zellij-jolt"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}╭──────────────────────────────────────────╮${NC}"
echo -e "${GREEN}│${NC}  ${YELLOW}zellij-jolt installer${NC}                    ${GREEN}│${NC}"
echo -e "${GREEN}╰──────────────────────────────────────────╯${NC}"
echo ""

# ── Helpers ─────────────────────────────────────────────────────────
gsettings_set_shortcut() {
    local name="$1"
    local binding="$2"
    local command="$3"

    local existing
    existing=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")

    local i=0
    while true; do
        local path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${i}/"
        if ! echo "$existing" | grep -q "$path"; then
            break
        fi
        local existing_binding
        existing_binding=$(gsettings get org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path" binding 2>/dev/null || echo "")
        if [[ "$existing_binding" == "'$binding'" ]]; then
            echo -e "${YELLOW}  Shortcut $binding already registered — updating command.${NC}"
            gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path" name "$name"
            gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path" command "$command"
            return
        fi
        i=$((i + 1))
    done

    local new_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${i}/"
    if [[ "$existing" == "@as []" ]]; then
        existing="['${new_path}']"
    else
        existing="${existing%]}, '${new_path}']"
    fi

    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$existing"
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$new_path" name "$name"
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$new_path" binding "$binding"
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$new_path" command "$command"
    echo -e "${GREEN}✓${NC} Registered $binding → $name"
}

# ── Check deps ──────────────────────────────────────────────────────
missing=()
for cmd in zellij fzf alacritty; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}Missing:${NC} ${missing[*]}"
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
    [[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ── Install ─────────────────────────────────────────────────────────
echo -e "${CYAN}Installing ${SCRIPT_NAME}...${NC}"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
cp "$SOURCE" "${INSTALL_DIR}/${SCRIPT_NAME}.sh"
chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}.sh"
ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}.sh" "${BIN_DIR}/${SCRIPT_NAME}"

echo -e "${GREEN}✓${NC} Installed to ${INSTALL_DIR}/${SCRIPT_NAME}.sh"
echo -e "${GREEN}✓${NC} Symlinked at ${BIN_DIR}/${SCRIPT_NAME}"
echo ""

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo -e "${YELLOW}Note:${NC} $BIN_DIR is not in your PATH."
    echo "Add to ~/.zshrc or ~/.bashrc:"
    echo -e "  ${CYAN}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
    echo ""
fi

# ── Alacritty config info ────────────────────────────────────────────
echo -e "${CYAN}Alacritty hook${NC}"
echo ""
echo "Add to ~/.config/alacritty/alacritty.toml:"
echo ""
echo -e "  ${CYAN}[terminal]${NC}"
echo -e "  ${CYAN}shell = \"${BIN_DIR}/${SCRIPT_NAME}\"${NC}"
echo ""
echo "Or use keyboard shortcuts (below) to keep normal terminals."
echo ""

# ── GNOME shortcuts ──────────────────────────────────────────────
if [[ "$XDG_CURRENT_DESKTOP" == "GNOME" ]]; then
    echo -e "${CYAN}GNOME Shortcuts${NC}"
    echo "Register these?"
    echo "  1) Ctrl+Enter         → Alacritty → Jolt"
    echo "  2) Ctrl+Shift+Enter   → Alacritty → Jolt"
    echo "  3) Both"
    echo "  n) No"
    echo ""
    read -rp "Choose [1/2/3/n]: " choice

    case "$choice" in
        1)
            gsettings_set_shortcut \
                "zellij-jolt" "<Control>Return" \
                "alacritty -e ${BIN_DIR}/zellij-jolt"
            ;;
        2)
            gsettings_set_shortcut \
                "zellij-jolt" "<Control><Shift>Return" \
                "alacritty -e ${BIN_DIR}/zellij-jolt"
            ;;
        3|"")
            gsettings_set_shortcut \
                "zellij-jolt" "<Control>Return" \
                "alacritty -e ${BIN_DIR}/zellij-jolt"
            gsettings_set_shortcut \
                "zellij-jolt-alt" "<Control><Shift>Return" \
                "alacritty -e ${BIN_DIR}/zellij-jolt"
            ;;
        *) echo "Skipping." ;;
    esac
    echo ""
else
    echo -e "${YELLOW}Non-GNOME detected — register shortcuts manually.${NC}"
    echo ""
fi

# ── Done ────────────────────────────────────────────────────────────
echo -e "${GREEN}╭──────────────────────────────────────────╮${NC}"
echo -e "${GREEN}│${NC}  ${YELLOW}Jolted in!${NC}                              ${GREEN}│${NC}"
echo -e "${GREEN}╰──────────────────────────────────────────╯${NC}"
echo ""
echo -e "Run ${GREEN}zellij-jolt${NC} to start the picker."
echo ""

echo -e "${CYAN}Next:${NC}"
echo "  1. Test:            zellij-jolt"
echo "  2. Alacritty hook:  add [terminal] shell = ..."
echo "  3. Or use shortcuts you just registered."
echo ""