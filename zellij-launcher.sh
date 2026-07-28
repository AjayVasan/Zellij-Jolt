#!/usr/bin/env bash
# zellij-launcher — Zellij session picker with fzf
#
# Launched by Alacritty (via shell config or -e flag). Shows existing Zellij
# sessions with fuzzy search, plus options for new sessions. Right preview
# pane shows session details: tabs, what's running in each, age, status.
set -euo pipefail
ZELLIJ_SESSION_DIR="${HOME}/.cache/zellij/contract_version_1/session_info"
export ZELLIJ_SESSION_DIR
VERSION="1.0.0"

# ── State machine parser for session-metadata.kdl ───────────────────
# Extracts tab names + pane titles from a single KDL file.
# Output: pipe-separated lines for display.
#   tab|<position>|<name>
#   pane|<tab_index>|<title>
#   age|<creation_minutes>
parse_metadata_file() {
    local meta_file="${ZELLIJ_SESSION_DIR}/${1}/session-metadata.kdl"
    [[ -f "$meta_file" ]] || return 1

    local section="" in_tab=0 in_pane=0
    local tab_pos="" tab_name="" tab_idx=-1
    local pane_title="" pane_is_plugin="" pane_tab_idx=""
    local line

    while IFS= read -r line; do
        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        # Section tracking
        if [[ "$line" == "tabs {" ]]; then section="tabs"; continue; fi
        if [[ "$line" == "panes {" ]]; then section="panes"; continue; fi
        if [[ "$line" == "}" ]] && [[ "$section" == "tabs" ]] && (( ! in_tab )); then
            section=""; continue
        fi
        if [[ "$line" == "}" ]] && [[ "$section" == "panes" ]] && (( ! in_pane )); then
            section=""; continue
        fi

        case "$section" in
            tabs)
                if [[ "$line" == "tab {" ]]; then
                    in_tab=1; tab_pos=""; tab_name=""; tab_idx=$((tab_idx+1))
                elif [[ "$line" == "}" ]]; then
                    in_tab=0
                    echo "tab|${tab_pos:-?}|${tab_name:-Tab #$((tab_idx+1))}"
                elif (( in_tab )); then
                    if [[ "$line" == name\ \"*\" ]]; then
                        tab_name="${line#*name \"}"; tab_name="${tab_name%\"}"
                    elif [[ "$line" == position\ * ]]; then
                        tab_pos="${line#position }"
                    fi
                fi
                ;;
            panes)
                if [[ "$line" == "pane {" ]]; then
                    in_pane=1; pane_title=""; pane_is_plugin=""; pane_tab_idx=""
                elif [[ "$line" == "}" ]]; then
                    in_pane=0
                    [[ "$pane_is_plugin" == "false" && -n "$pane_title" ]] \
                        && echo "pane|${pane_tab_idx:-?}|${pane_title}"
                elif (( in_pane )); then
                    if [[ "$line" == title\ \"*\" ]]; then
                        pane_title="${line#*title \"}"; pane_title="${pane_title%\"}"
                    elif [[ "$line" == is_plugin\ * ]]; then
                        pane_is_plugin="${line#is_plugin }"
                    elif [[ "$line" == tab_position\ * ]]; then
                        pane_tab_idx="${line#tab_position }"
                    fi
                fi
                ;;
        esac
    done < "$meta_file"
}

# ── Preview builder (called from fzf --preview) ────────────────────
session_preview() {
    local item="$1"

    case "$item" in
        "── New Untracked ──")
            printf '\e[0;32m'
            echo '  ╭──────────────────────────────────────────────╮'
            printf '  │ \e[1;37m  + New Untracked Session\e[0;32m                   │\n'
            echo '  ├──────────────────────────────────────────────┤'
            printf '  │ \e[0;37m  Creates an auto-named Zellij session.\e[0;32m      │\n'
            printf '  │ \e[0;37m  Zellij generates a random adjective-animal\e[0;32m  │\n'
            printf '  │ \e[0;37m  name automatically.\e[0;32m                        │\n'
            echo '  ╰──────────────────────────────────────────────╯'
            printf '\e[0m'
            return
            ;;
        "── New Named ──")
            printf '\e[0;32m'
            echo '  ╭──────────────────────────────────────────────╮'
            printf '  │ \e[1;37m  + New Named Session\e[0;32m                        │\n'
            echo '  ├──────────────────────────────────────────────┤'
            printf '  │ \e[0;37m  Prompts for a custom session name.\e[0;32m          │\n'
            printf '  │ \e[0;37m  Useful for project-specific sessions.\e[0;32m       │\n'
            echo '  ╰──────────────────────────────────────────────╯'
            printf '\e[0m'
            return
            ;;
        "── Cancel ──")
            printf '\e[0;31m'
            echo '  ╭──────────────────────────────────────────────╮'
            printf '  │ \e[1;37m  Cancel\e[0;31m                                    │\n'
            echo '  ├──────────────────────────────────────────────┤'
            printf '  │ \e[0;37m  Exits without opening a session.\e[0;31m            │\n'
            echo '  ╰──────────────────────────────────────────────╯'
            printf '\e[0m'
            return
            ;;
    esac

    # Real session
    local session_info
    session_info=$(zellij list-sessions -n 2>/dev/null | grep "^${item} " || true)
    if [[ -z "$session_info" ]]; then
        printf '\e[0;33m  (session not found)\e[0m\n'
        return
    fi

    # Parse age & status
    local age="${session_info#*[Created }"
    age="${age%%]*}"
    local status="ACTIVE"
    [[ "$session_info" == *"(EXITED"* ]] && status="EXITED (resurrect)"

    # Parse metadata
    local meta_output
    meta_output=$(parse_metadata_file "$item" 2>/dev/null || echo "NOCACHE")
    if [[ "$meta_output" == "NOCACHE" ]]; then
        # No cached data — show basic info
        printf '\e[0;32m'
        echo '  ╭──────────────────────────────────────────────╮'
        printf '  │ \e[1;37m%-44s\e[0;32m │\n' "${item:0:44}"
        echo '  ├──────────────────────────────────────────────┤'
        printf '  │ \e[0;37mAge:    \e[0;33m%-36s\e[0;32m │\n' "${age:0:36}"
        printf '  │ \e[0;37mStatus: \e[0;36m%-36s\e[0;32m │\n' "${status:0:36}"
        printf '  │ \e[0;37mTabs:   \e[0;33m%-36s\e[0;32m │\n' "(no cached data)"
        echo '  ╰──────────────────────────────────────────────╯'
        printf '\e[0m'
        return
    fi

    # Collect tabs and panes
    local tabs=() panes_by_tab=()
    while IFS='|' read -r kind a b; do
        if [[ "$kind" == "tab" ]]; then
            tabs+=("$a|$b")
        elif [[ "$kind" == "pane" ]]; then
            panes_by_tab[$a]+="${b}, "
        fi
    done <<< "$meta_output"

    local tab_count="${#tabs[@]}"

    # Render
    printf '\e[0;32m'
    echo '  ╭──────────────────────────────────────────────╮'
    printf '  │ \e[1;37m%-44s\e[0;32m │\n' "${item:0:44}"
    echo '  ├──────────────────────────────────────────────┤'
    printf '  │ \e[0;37mAge:    \e[0;33m%-36s\e[0;32m │\n' "${age:0:36}"
    printf '  │ \e[0;37mStatus: \e[0;36m%-36s\e[0;32m │\n' "${status:0:36}"
    printf '  │ \e[0;37mTabs:   \e[0;33m%-36s\e[0;32m │\n' "$tab_count"
    echo '  ├──────────────────────────────────────────────┤'

    if (( tab_count == 0 )); then
        printf '  │ \e[0;37m  No tabs yet\e[0;32m                              │\n'
    else
        local idx=0
        for tab_entry in "${tabs[@]}"; do
            local pos="${tab_entry%%|*}"
            local name="${tab_entry#*|}"
            # Get pane for this tab
            local pane_info="${panes_by_tab[$idx]:-}"
            pane_info="${pane_info%, }"
            if [[ -n "$pane_info" ]]; then
                pane_info="${pane_info:0:30}"
                printf '  │  \e[0;36m%-3s\e[0;37m %-38s\e[0;32m │\n' "${pos}." "${name:0:38}"
                printf '  │  \e[0;37m     └ %-35s\e[0;32m │\n' "${pane_info:0:35}"
            else
                printf '  │  \e[0;36m%-3s\e[0;37m %-38s\e[0;32m │\n' "${pos}." "${name:0:38}"
            fi
            idx=$((idx+1))
        done
    fi

    echo '  ╰──────────────────────────────────────────────╯'
    printf '\e[0m'
}

# ── Main ────────────────────────────────────────────────────────────
main() {
    for cmd in zellij fzf; do
        command -v "$cmd" &>/dev/null || { echo "Error: $cmd required"; exit 1; }
    done

    # Build input for fzf
    local sessions
    sessions=$(zellij list-sessions -s 2>/dev/null || true)
    local fzf_input=""
    if [[ -n "$sessions" ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] && fzf_input+="$s"$'\n'
        done <<< "$sessions"
    fi
    fzf_input+='── New Untracked ──'$'\n''── New Named ──'$'\n''── Cancel ──'

    # Ensure TTY stdin for fzf interaction
    exec < /dev/tty

    local selected
    selected=$(
        echo "$fzf_input" \
        | fzf --ansi \
              --layout=reverse \
              --info=inline \
              --border=sharp \
              --border-label=' Zellij Session Launcher ' \
              --border-label-pos=3 \
              --header=' Ctrl-n:New Untracked  Ctrl-N:New Named  Esc:Cancel' \
              --header-first \
              --header-border=sharp \
              --color='bg:#1a1a2e,bg+:#16213e,fg:#d3d7cf,fg+:#ffffff,hl:#4e9a06,hl+:#8ae234' \
              --color='gutter:#1a1a2e,info:#06989a,pointer:#4e9a06,marker:#4e9a06,spinner:#c4a000' \
              --color='header:#555753,prompt:#06989a,border:#4e9a06' \
              --color='preview-bg:#0f0f1a,preview-fg:#d3d7cf' \
              --prompt='🔍 ' \
              --bind='ctrl-n:become(echo "── New Untracked ──")' \
              --bind='ctrl-N:become(echo "── New Named ──")' \
              --preview="
                  item={};
                  $(declare -f session_preview parse_metadata_file);
                  session_preview \"\$item\"
              " \
              --preview-window='right:60%:border-sharp' \
              --preview-label=' Session Details ' \
              --preview-label-pos=3
    )

    case "$selected" in
        "── New Untracked ──")
            exec zellij
            ;;
        "── New Named ──")
            echo -n "Session name: "
            read -r session_name
            [[ -z "$session_name" ]] && { echo "Cancelled."; exit 0; }
            exec zellij -s "$session_name"
            ;;
        "── Cancel ──"|"")
            exit 0
            ;;
        *)
            if zellij list-sessions -s 2>/dev/null | grep -qxF "$selected"; then
                exec zellij attach "$selected"
            else
                exec zellij attach "$selected" 2>/dev/null || exec zellij -s "$selected"
            fi
            ;;
    esac
}

main "$@"