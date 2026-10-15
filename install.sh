#!/usr/bin/env bash
# zellij-jolt installer
#
# Installs zellij-jolt.sh to ${XDG_DATA_HOME:-~/.local/share}/zellij-jolt/
# and symlinks it at ${XDG_BIN_HOME:-~/.local/bin}/zellij-jolt. Checks for
# zellij/fzf (required) and warns on versions below the floors this
# script supports; detects which terminal emulators are present and
# prints the exact config snippet for each, plus the --init-shell hint;
# optionally (opt-in, never with --yes) registers a GNOME custom keyboard
# shortcut. `--uninstall` removes the symlink and install dir only — it
# never touches shell rc files, terminal config, or GNOME shortcuts.
#
# When sourced with JOLT_INSTALL_NO_MAIN=1, only defines functions (used
# by test/install.bats to unit-test the GNOME duplicate-scan logic
# directly, since --yes / non-tty stdin always skip that path end-to-end).
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="zellij-jolt"
SOURCE="$REPO_DIR/$SCRIPT_NAME.sh"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zellij-jolt"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"

FLOOR_ZELLIJ="0.39"
FLOOR_FZF="0.38"

TERMINALS=(alacritty ghostty kitty wezterm foot)

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

YES=0
NO_SHORTCUT=0
UNINSTALL=0

# ── Small helpers ─────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: install.sh [--yes] [--no-shortcut] [--uninstall] [--help]

  --yes           Non-interactive: accept every default, never prompt.
  --no-shortcut   Skip the GNOME keyboard-shortcut question entirely.
  --uninstall     Remove the installed script and symlink, then exit.
  --help          Show this help.

A PATH that isn't a terminal (e.g. piped input) behaves like --yes.
EOF
}

# extract_version RAW — first dotted-numeric token in RAW, e.g. turns
# "zellij 0.45.1" or "0.74.5 (abc)" into "0.45.1" / "0.74.5".
extract_version() {
    local raw="$1" tok
    for tok in $raw; do
        if [[ "$tok" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
            printf '%s\n' "$tok"
            return 0
        fi
    done
    return 1
}

# version_ge V FLOOR — true when V >= FLOOR (dotted-numeric versions).
version_ge() {
    local v="$1" floor="$2"
    [[ "$(printf '%s\n%s\n' "$floor" "$v" | sort -V | head -n1)" == "$floor" ]]
}

# detect_pkg_mgr — echoes the first package manager found on PATH.
detect_pkg_mgr() {
    local mgr
    for mgr in pacman apt dnf brew; do
        if command -v "$mgr" >/dev/null 2>&1; then
            printf '%s\n' "$mgr"
            return 0
        fi
    done
    return 1
}

# pkg_install_hint MGR PKG... — the install command for that manager.
pkg_install_hint() {
    local mgr="$1"
    shift
    case "$mgr" in
        pacman) printf 'sudo pacman -S %s\n' "$*" ;;
        apt) printf 'sudo apt install %s\n' "$*" ;;
        dnf) printf 'sudo dnf install %s\n' "$*" ;;
        brew) printf 'brew install %s\n' "$*" ;;
        *) printf 'Install %s using your package manager.\n' "$*" ;;
    esac
}

# terminal_snippet TERM PATH — exact config snippet for that terminal.
terminal_snippet() {
    local term="$1" path="$2"
    case "$term" in
        alacritty) printf '[terminal]\nshell = "%s"' "$path" ;;
        ghostty) printf 'command = %s' "$path" ;;
        kitty) printf 'shell %s' "$path" ;;
        wezterm) printf 'config.default_prog = { "%s" }' "$path" ;;
        foot) printf '[main]\nshell=%s' "$path" ;;
    esac
}

# gnome_detected — true when XDG_CURRENT_DESKTOP names GNOME among its
# colon-separated components (handles unset, bare "GNOME", and compound
# values like "ubuntu:GNOME").
gnome_detected() {
    [[ ":${XDG_CURRENT_DESKTOP:-}:" == *:GNOME:* ]]
}

# ── GNOME custom-keybinding helpers ───────────────────────────────────

# gsettings_existing_paths — one existing custom-keybinding dconf path
# per line, parsed out of `gsettings get ... custom-keybindings` (a
# GVariant array-of-strings literal) by pulling every '...'-quoted token.
gsettings_existing_paths() {
    local raw
    raw="$(gsettings get org.gnome.settings-daemon.plugins.media-keys \
        custom-keybindings 2>/dev/null || echo "@as []")"
    grep -o "'[^']*'" <<<"$raw" | tr -d "'"
}

# gsettings_next_custom_path — the lowest customN/ path not already in
# the existing list. Scans every existing path (not just the list's
# length), so a gap left by a removed shortcut is reused correctly.
gsettings_next_custom_path() {
    local -a existing
    mapfile -t existing < <(gsettings_existing_paths)
    local n=0
    while true; do
        local candidate="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${n}/"
        local taken=0 p
        for p in "${existing[@]}"; do
            if [[ "$p" == "$candidate" ]]; then
                taken=1
                break
            fi
        done
        if [[ $taken -eq 0 ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        n=$((n + 1))
    done
}

# gsettings_register_shortcut NAME BINDING COMMAND — picks the next free
# custom path, appends it to the custom-keybindings list, and sets its
# name/binding/command.
gsettings_register_shortcut() {
    local name="$1" binding="$2" command="$3"
    local path
    path="$(gsettings_next_custom_path)"

    local -a existing
    mapfile -t existing < <(gsettings_existing_paths)
    existing+=("$path")

    local joined="" p
    for p in "${existing[@]}"; do
        if [[ -z "$joined" ]]; then
            joined="'$p'"
        else
            joined="$joined, '$p'"
        fi
    done

    gsettings set org.gnome.settings-daemon.plugins.media-keys \
        custom-keybindings "[$joined]"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" \
        name "$name"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" \
        binding "$binding"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" \
        command "$command"
    echo -e "${GREEN}✓${NC} Registered $binding -> $name"
}

# ── Steps ──────────────────────────────────────────────────────────────

print_header() {
    echo -e "${GREEN}╭──────────────────────────────────────────╮${NC}"
    echo -e "${GREEN}│${NC}  ${YELLOW}zellij-jolt installer${NC}                    ${GREEN}│${NC}"
    echo -e "${GREEN}╰──────────────────────────────────────────╯${NC}"
    echo ""
}

check_dependencies() {
    local -a required=(zellij fzf)
    local -a missing=()
    local c
    for c in "${required[@]}"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    echo -e "${RED}Missing:${NC} ${missing[*]}"
    local mgr
    if mgr="$(detect_pkg_mgr)"; then
        echo -e "${YELLOW}Install them first:${NC}"
        echo "  $(pkg_install_hint "$mgr" "${missing[@]}")"
    else
        echo -e "${YELLOW}Install them first using your package manager.${NC}"
    fi
    echo ""

    if [[ $YES -eq 1 ]]; then
        echo -e "${YELLOW}Continuing without them (--yes).${NC}"
        echo ""
        return 0
    fi

    local yn
    read -rp "Continue anyway? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

_check_floor() {
    local cmd="$1" floor="$2" raw ver
    command -v "$cmd" >/dev/null 2>&1 || return 0
    raw="$("$cmd" --version 2>/dev/null || true)"
    ver="$(extract_version "$raw")" || return 0
    if ! version_ge "$ver" "$floor"; then
        echo -e "${YELLOW}Warning:${NC} $cmd $ver is older than the recommended $floor floor."
    fi
}

check_version_floors() {
    _check_floor zellij "$FLOOR_ZELLIJ"
    _check_floor fzf "$FLOOR_FZF"
}

do_install() {
    echo -e "${CYAN}Installing ${SCRIPT_NAME}...${NC}"
    mkdir -p "$INSTALL_DIR" "$BIN_DIR"
    cp "$SOURCE" "${INSTALL_DIR}/${SCRIPT_NAME}.sh"
    chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}.sh"
    ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}.sh" "${BIN_DIR}/${SCRIPT_NAME}"
    echo -e "${GREEN}✓${NC} Installed to ${INSTALL_DIR}/${SCRIPT_NAME}.sh"
    echo -e "${GREEN}✓${NC} Symlinked at ${BIN_DIR}/${SCRIPT_NAME}"
    echo ""
}

do_uninstall() {
    print_header
    rm -f "${BIN_DIR}/${SCRIPT_NAME}"
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}✓${NC} Removed ${BIN_DIR}/${SCRIPT_NAME}"
    echo -e "${GREEN}✓${NC} Removed ${INSTALL_DIR}"
    echo ""
    echo "This did not touch:"
    echo "  - any shell rc auto-start snippet (zellij-jolt --init-shell)"
    echo "  - any terminal config (alacritty/ghostty/kitty/wezterm/foot)"
    echo "  - any GNOME custom keyboard shortcut"
    echo "Remove those by hand if you added them."
}

print_path_hint() {
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        echo -e "${YELLOW}Note:${NC} $BIN_DIR is not in your PATH."
        echo "Add to your shell rc:"
        echo -e "  ${CYAN}export PATH=\"$BIN_DIR:\$PATH\"${NC}"
        echo ""
    fi
}

print_terminal_snippets() {
    local term found=0
    for term in "${TERMINALS[@]}"; do
        if command -v "$term" >/dev/null 2>&1; then
            found=1
            echo -e "${CYAN}${term} hook${NC}"
            echo ""
            echo -e "${CYAN}$(terminal_snippet "$term" "${BIN_DIR}/${SCRIPT_NAME}")${NC}"
            echo ""
        fi
    done
    if [[ $found -eq 0 ]]; then
        echo "No supported terminal emulator found on PATH."
        echo "Configure yours to run: ${BIN_DIR}/${SCRIPT_NAME}"
        echo ""
    fi
}

print_init_shell_hint() {
    local shell_name
    shell_name="$(basename "${SHELL:-sh}")"
    echo -e "${CYAN}Or auto-start on shell login${NC}"
    echo "Run this to see the guarded snippet for your shell:"
    echo -e "  ${CYAN}${SCRIPT_NAME} --init-shell ${shell_name}${NC}"
    echo ""
}

maybe_register_gnome_shortcut() {
    if [[ $NO_SHORTCUT -eq 1 ]]; then
        return 0
    fi
    if ! gnome_detected; then
        echo -e "${YELLOW}Non-GNOME (or unknown) desktop — register a shortcut manually if you want one.${NC}"
        echo ""
        return 0
    fi
    # Never ask, and never register, non-interactively.
    if [[ $YES -eq 1 ]]; then
        return 0
    fi

    echo -e "${CYAN}GNOME detected.${NC}"
    local ans
    read -rp "Register a GNOME keyboard shortcut to launch zellij-jolt? [y/N] " ans || ans="n"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        gsettings_register_shortcut "zellij-jolt" "<Control><Shift>Return" \
            "${BIN_DIR}/${SCRIPT_NAME}"
    fi
    echo ""
}

print_done() {
    echo -e "${GREEN}╭──────────────────────────────────────────╮${NC}"
    echo -e "${GREEN}│${NC}  ${YELLOW}Jolted in!${NC}                              ${GREEN}│${NC}"
    echo -e "${GREEN}╰──────────────────────────────────────────╯${NC}"
    echo ""
    echo -e "Run ${GREEN}zellij-jolt${NC} to start the picker."
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) YES=1 ;;
            --no-shortcut) NO_SHORTCUT=1 ;;
            --uninstall) UNINSTALL=1 ;;
            --help | -h)
                usage
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option:${NC} $1" >&2
                usage >&2
                exit 1
                ;;
        esac
        shift
    done

    # A PATH that isn't a terminal (piped input, CI, etc.) behaves like
    # --yes: no prompt can be answered, so none should be attempted.
    if [[ ! -t 0 ]]; then
        YES=1
    fi
}

main() {
    parse_args "$@"

    if [[ $UNINSTALL -eq 1 ]]; then
        do_uninstall
        exit 0
    fi

    print_header
    check_dependencies
    check_version_floors
    do_install
    print_path_hint
    print_terminal_snippets
    print_init_shell_hint
    maybe_register_gnome_shortcut
    print_done
}

if [[ "${JOLT_INSTALL_NO_MAIN:-0}" != "1" ]]; then
    main "$@"
fi
