#!/usr/bin/env bash
# zellij-jolt — Jolt into your Zellij sessions
#
# Launched by Alacritty (via shell config or -e flag). Shows existing Zellij
# sessions with fuzzy search, plus options for new sessions. Right preview
# pane shows session details: tabs, what's running in each, age, status.
set -euo pipefail

VERSION="1.0.0"
ZELLIJ_SESSION_DIR="${HOME}/.cache/zellij/contract_version_1/session_info"
export ZELLIJ_SESSION_DIR

# ── Gruber Darker theme ────────────────────────────────────────────
# Mirrors the user's Zellij `gruber-darker` theme exactly.
#   bg=#181818  fg=#f4f4f4  green=#73d936  cyan=#95a99f
#   yellow=#ffdd7e  red=#f43841  blue=#96a6c8  magenta=#9e95c7
C_RESET=$'\e[0m'
C_BOLD=$'\e[1m'
C_BD=$'\e[38;2;115;217;54m'          # green   — box borders, structural
C_TL=$'\e[1;38;2;244;244;244m'       # bold fg — title (session name)
C_LB=$'\e[38;2;244;244;244m'         # fg      — labels (Age:, Status:, etc.)
C_VL=$'\e[38;2;255;221;126m'         # yellow  — values (age numbers)
C_ST=$'\e[38;2;149;169;159m'         # cyan    — status line, tab pos numbers
C_TN=$'\e[38;2;244;244;244m'         # fg      — tab names
C_PN=$'\e[38;2;228;228;228m'         # white   — pane info (slightly dimmer)
C_ER=$'\e[38;2;244;56;65m'           # red     — cancel / error
C_HL=$'\e[38;2;255;221;126m'         # yellow  — highlight accent
FZF_COLORS="\
bg:#181818,bg+:#242424,\
fg:#e4e4e4,fg+:#f4f4f4,\
hl:#73d936,hl+:#73d936,\
gutter:#181818,\
info:#95a99f,\
pointer:#73d936,marker:#73d936,\
spinner:#ffdd7e,\
header:#505050,\
prompt:#95a99f,\
border:#73d936,\
preview-bg:#101010,preview-fg:#e4e4e4"

# ── State machine parser for session-metadata.kdl ───────────────────
# Extracts tab names + pane titles from a single KDL file.
# Output: pipe-separated lines for display.
#   tab|<position>|<name>
#   pane|<tab_index>|<title>
parse_metadata_file() {
    local meta_file="${ZELLIJ_SESSION_DIR}/${1}/session-metadata.kdl"
    [[ -f "$meta_file" ]] || return 1

    local section="" in_tab=0 in_pane=0
    local tab_pos="" tab_name="" tab_idx=-1
    local pane_title="" pane_is_plugin="" pane_tab_idx=""
    local line

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

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

# ── Render helpers — all produce exactly 46 chars between │...│ ──────
# Inner width = 46 (matches the 46 ─ chars in the border line).
# Every helper pads/truncates to fill exactly 46 visible chars.
_box_top()    { printf "${C_BD}  ╭──────────────────────────────────────────────╮${C_RESET}\n"; }
_box_sep()    { printf "${C_BD}  ├──────────────────────────────────────────────┤${C_RESET}\n"; }
_box_bot()    { printf "${C_BD}  ╰──────────────────────────────────────────────╯${C_RESET}\n"; }
_box_title()  { printf "${C_BD}  │${C_RESET} ${C_TL}%-44s${C_RESET} ${C_BD}│${C_RESET}\n" "${1:0:44}"; }
_box_label()  { printf "${C_BD}  │${C_RESET} ${C_LB}%-7s${C_RESET} ${C_VL}%-36s${C_RESET} ${C_BD}│${C_RESET}\n" "$1" "${2:0:36}"; }
_box_line()   { printf "${C_BD}  │${C_RESET} %-44s ${C_BD}│${C_RESET}\n" "$1"; }
_box_tab()    { printf "${C_BD}  │${C_RESET}  ${C_ST}%-3s${C_RESET} ${C_TN}%-39s${C_RESET} ${C_BD}│${C_RESET}\n" "$1" "${2:0:39}"; }
_box_pane()   { printf "${C_BD}  │${C_RESET}  ${C_PN}     └ %-37s${C_RESET} ${C_BD}│${C_RESET}\n" "${1:0:37}"; }
_box_empty()  { printf "${C_BD}  │${C_RESET} %-44s ${C_BD}│${C_RESET}\n" ""; }

# ── Preview builder (called from fzf --preview) ────────────────────
session_preview() {
    local item="$1"
    case "$item" in
        "── New Tracked ──"|"── New Named ──")
            _box_top
            _box_title "+ New Named Session"
            _box_sep
            _box_line "Prompts for a custom session name via"
            _box_line "terminal input, then creates a Zellij"
            _box_line "session with that name."
            _box_bot
            return
            ;;
        "── New Untracked ──")
            _box_top
            _box_title "+ New Untracked Session"
            _box_sep
            _box_line "Creates an auto-named Zellij session."
            _box_line "Zellij generates a random adjective-"
            _box_line "animal name like 'funky-sloth'."
            _box_bot
            return
            ;;
        "── Resume ──")
            _box_top
            _box_title "→ Resume Session"
            _box_sep
            _box_line "Lists all sessions with their age and"
            _box_line "tab count. Select one to attach."
            _box_bot
            return
            ;;
        "── Exit ──"|"── Cancel ──")
            _box_top
            _box_title "Exit"
            _box_sep
            _box_line "Closes the picker and exits."
            _box_bot
            return
            ;;
    esac

    # Real session
    local session_info
    session_info=$(zellij list-sessions -n 2>/dev/null | grep "^${item} " || true)
    if [[ -z "$session_info" ]]; then
        printf "${C_HL}  (session not found)${C_RESET}\n"
        return
    fi

    local age="${session_info#*[Created }"
    age="${age%%]*}"
    local status="ACTIVE"
    [[ "$session_info" == *"(EXITED"* ]] && status="EXITED (resurrect)"

    local meta_output
    meta_output=$(parse_metadata_file "$item" 2>/dev/null || echo "NOCACHE")

    if [[ "$meta_output" == "NOCACHE" ]]; then
        _box_top
        _box_title "$item"
        _box_sep
        _box_label "Age:"    "$age"
        _box_label "Status:" "$status"
        _box_label "Tabs:"   "(no cached data)"
        _box_bot
        return
    fi

    local tabs=() panes_by_tab=()
    while IFS='|' read -r kind a b; do
        if [[ "$kind" == "tab" ]]; then
            tabs+=("$a|$b")
        elif [[ "$kind" == "pane" ]]; then
            panes_by_tab[$a]+="${b}, "
        fi
    done <<< "$meta_output"

    local tab_count="${#tabs[@]}"

    _box_top
    _box_title "$item"
    _box_sep
    _box_label "Age:"    "$age"
    _box_label "Status:" "$status"
    _box_label "Tabs:"   "$tab_count"
    _box_sep

    if (( tab_count == 0 )); then
        _box_line "  No tabs yet"
    else
        local idx=0
        for tab_entry in "${tabs[@]}"; do
            local pos="${tab_entry%%|*}"
            local name="${tab_entry#*|}"
            local pane_info="${panes_by_tab[$idx]:-}"
            pane_info="${pane_info%, }"
            if [[ -n "$pane_info" ]]; then
                pane_info="${pane_info:0:30}"
                _box_tab "${pos}." "${name}"
                _box_pane "${pane_info}"
            else
                _box_tab "${pos}." "${name}"
            fi
            idx=$((idx+1))
        done
    fi

    _box_bot
}

# ── Main ────────────────────────────────────────────────────────────
main() {
    for cmd in zellij fzf; do
        command -v "$cmd" &>/dev/null || { echo "Error: $cmd required"; exit 1; }
    done

    local sessions
    sessions=$(zellij list-sessions -s 2>/dev/null || true)
    local fzf_input=""
    if [[ -n "$sessions" ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] && fzf_input+="$s"$'\n'
        done <<< "$sessions"
    fi
    fzf_input+=$'\n''── New Tracked ──'$'\n''── New Untracked ──'$'\n''── Resume ──'$'\n''── Exit ──'

    exec < /dev/tty

    local selected
    selected=$(
        echo "$fzf_input" \
        | fzf --ansi \
              --layout=reverse \
              --info=inline \
              --border=sharp \
              --border-label=' Zellij-Jolt ' \
              --border-label-pos=3 \
              --header=' Ctrl-n:New  Ctrl-N:Tracked  Ctrl-r:Resume  Esc:Exit' \
              --header-first \
              --header-border=sharp \
              --color="${FZF_COLORS}" \
              --prompt='🔍 ' \
              --bind='ctrl-n:become(echo "── New Untracked ──")' \
              --bind='ctrl-N:become(echo "── New Tracked ──")' \
              --bind='ctrl-r:become(echo "── Resume ──")' \
              --preview="
                  item={};
                  $(declare -f session_preview parse_metadata_file \
                              _box_top _box_sep _box_bot _box_title \
                              _box_label _box_line _box_tab _box_pane _box_empty);
                  session_preview \"\$item\"
              " \
              --preview-window='right:60%:border-sharp' \
              --preview-label=' Session Details ' \
              --preview-label-pos=3
    )

    case "$selected" in
        "── New Tracked ──")
            echo -n "Session name: "
            read -r session_name
            [[ -z "$session_name" ]] && { echo "Cancelled."; exit 0; }
            exec zellij -s "$session_name"
            ;;
        "── New Untracked ──")
            exec zellij
            ;;
        "── Resume ──")
            # Build a detailed session list and run a sub-picker
            local resume_list=""
            while IFS= read -r line; do
                local sname="${line%% *}"
                local sinfo="${line#* }"
                resume_list+="${sname}  ${sinfo}"$'\n'
            done < <(zellij list-sessions -n 2>/dev/null || true)
            if [[ -z "$resume_list" ]]; then
                printf "${C_HL}  No sessions to resume.${C_RESET}\n"
                exit 0
            fi
            local chosen
            chosen=$(
                echo "$resume_list" | fzf --ansi \
                    --layout=reverse --info=inline \
                    --border=sharp \
                    --border-label=' Resume Session ' \
                    --border-label-pos=3 \
                    --color="${FZF_COLORS}" \
                    --prompt='🔍 ' \
                    --preview="
                        item=\$(echo {} | awk '{print \$1}');
                        $(declare -f session_preview parse_metadata_file \
                                    _box_top _box_sep _box_bot _box_title \
                                    _box_label _box_line _box_tab _box_pane _box_empty);
                        session_preview \"\$item\"
                    " \
                    --preview-window='right:60%:border-sharp' \
                    --preview-label=' Session Details ' \
                    --preview-label-pos=3
            )
            if [[ -n "$chosen" ]]; then
                local sname="${chosen%%  *}"
                exec zellij attach "$sname"
            fi
            exit 0
            ;;
        "── Exit ──"|"── Cancel ──"|"")
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