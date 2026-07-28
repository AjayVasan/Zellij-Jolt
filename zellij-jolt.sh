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

_load_theme() {
    # Reads the active Zellij theme from config.kdl and sets color variables.
    # Works for any theme defined inline (themes { name { ... } }) or in
    # an external <theme_dir>/<name>.kdl file. Falls back to Zellij's
    # built-in default palette when no theme is configured.
    #
    # Sets these globals: C_RESET C_BOLD C_BD C_TL C_LB C_VL C_ST C_TN C_PN
    #                     C_HL C_ITA FZF_COLORS

    # ── Helpers for building ANSI 24-bit sequences ──────────────────
    _rgb()  { printf '\e[38;2;%s;%s;%sm' "$1" "$2" "$3"; }
    _bold_rgb() { printf '\e[1;38;2;%s;%s;%sm' "$1" "$2" "$3"; }

    # ── Default fallback palette (Zellij's built-in default) ────────
    # When no theme is configured, Zellij uses the terminal's default
    # color palette (indexed 0-15). We approximate with a neutral dark
    # scheme matching the commented-out defaults in --dump-config.
    local dfg="248 248 242" dbg="40 42 54"
    local dred="255 85 85"  dgreen="80 250 123"
    local dyellow="241 250 140" dblue="98 114 164"
    local dmagenta="255 121 198" dorange="255 184 108"
    local dcyan="139 233 253"    dblack="0 0 0"
    local dwhite="255 255 255"
    local config_file theme_name theme_dir all_lines i line
    declare -gA _raw=()
    config_file="${ZELLIJ_CONFIG_FILE:-$HOME/.config/zellij/config.kdl}"

    if [[ -f "$config_file" ]]; then
        # Read config, strip comments, store non-empty lines
        mapfile -t all_lines < <(
            while IFS= read -r raw || [[ -n "$raw" ]]; do
                local trimmed="${raw%%//*}"
                trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
                trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
                [[ -z "$trimmed" ]] && continue
                printf '%s\n' "$trimmed"
            done < "$config_file"
        )

        # ── Pass 1: find theme_name, theme_dir ─────────────────────
        for line in "${all_lines[@]}"; do
            if [[ "$line" == theme\ \"*\" ]]; then
                theme_name="${line#*\"}"; theme_name="${theme_name%%\"*}"
            elif [[ "$line" == theme\ * ]]; then
                theme_name="${line#theme }"
            fi
            if [[ "$line" == theme_dir\ \"*\" ]]; then
                theme_dir="${line#*\"}"; theme_dir="${theme_dir%%\"*}"
            fi
        done

        # ── Pass 2: find matching theme block and extract colors ───
        if [[ -n "$theme_name" && "$theme_name" != "default" ]]; then
            local in_themes=0 in_this=0 found=0
            for line in "${all_lines[@]}"; do
                if [[ "$in_themes" == 0 && "$line" == "themes {" ]]; then
                    in_themes=1; continue
                fi
                if [[ "$in_themes" == 1 && "$line" == "}" ]]; then
                    if [[ "$found" == 1 ]]; then break; fi
                    in_themes=0; continue
                fi
                [[ "$in_themes" == 0 ]] && continue

                # Inside themes: find matching name block
                if [[ "$line" == *"{"* ]] && [[ "$line" != "}" ]]; then
                    local cand="${line%\{*}"
                    cand="${cand%"${cand##*[![:space:]]}"}"
                    in_this=0
                    if [[ "$cand" == "$theme_name" ]]; then
                        in_this=1; found=1
                    fi
                    continue
                fi
                if [[ "$line" == "}" ]]; then
                    in_this=0; continue
                fi

                if [[ "$in_this" == 1 ]]; then
                    local cname _cr _cg _cb
                    read -r cname _cr _cg _cb <<< "$line"
                    if [[ -n "$cname" && -n "${_cr:-}" && -n "${_cg:-}" && -n "${_cb:-}" ]]; then
                        _raw["$cname"]="${_cr} ${_cg} ${_cb}"
                    fi
                fi
            done
        fi
    fi

    # ── Apply colors ─────────────────────────────────────────────
    if [[ ${#_raw[@]} -gt 0 ]]; then

        # If we have a theme name, apply its colors
        if [[ -n "$theme_name" && "$theme_name" != "default" ]]; then
            if [[ ${#_raw[@]} -gt 0 ]]; then
                # Map colors from the parsed theme
                local fg="${_raw[fg]:-$dfg}"   bg="${_raw[bg]:-$dbg}"
                local red="${_raw[red]:-$dred}" green="${_raw[green]:-$dgreen}"
                local yellow="${_raw[yellow]:-$dyellow}" blue="${_raw[blue]:-$dblue}"
                local magenta="${_raw[magenta]:-$dmagenta}" orange="${_raw[orange]:-$dorange}"
                local cyan="${_raw[cyan]:-$dcyan}" black="${_raw[black]:-$dblack}"
                local white="${_raw[white]:-$dwhite}"


                # Build final color variables
                C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'
                C_BD=$(_rgb $green)          # green   — box borders, structural
                C_TL=$(_bold_rgb $fg)        # bold fg — title
                C_LB=$(_rgb $fg)             # fg      — labels
                C_VL=$(_rgb $yellow)         # yellow  — values
                C_ST=$(_rgb $cyan)           # cyan    — status, tab positions
                C_TN=$(_rgb $fg)             # fg      — tab names
                C_PN=$(_rgb $white)          # white   — pane info
                C_HL=$(_rgb $yellow)         # yellow  — highlight
                C_ITA=$'\e[3m'              # italic

                # Derive brighter bg for fzf bg+ (mix bg + 15%)
                local br=0 bg_r bg_g bg_b
                read -r bg_r bg_g bg_b <<< "$bg"
                br=$(( bg_r + (255 - bg_r) * 15 / 100 ))
                local bg_r2=$br
                br=$(( bg_g + (255 - bg_g) * 15 / 100 ))
                local bg_g2=$br
                br=$(( bg_b + (255 - bg_b) * 15 / 100 ))
                local bg_b2=$br

                # Derive slightly dimmer fg for fzf
                local fg_r fg_g fg_b
                read -r fg_r fg_g fg_b <<< "$fg"
                br=$(( fg_r * 9 / 10 ))
                local fg2_r=$br
                br=$(( fg_g * 9 / 10 ))
                local fg2_g=$br
                br=$(( fg_b * 9 / 10 ))
                local fg2_b=$br

                FZF_COLORS="\
bg:$(printf '#%02x%02x%02x' $bg_r $bg_g $bg_b),\
bg+:$(printf '#%02x%02x%02x' $bg_r2 $bg_g2 $bg_b2),\
fg:$(printf '#%02x%02x%02x' $fg2_r $fg2_g $fg2_b),\
fg+:$(printf '#%02x%02x%02x' $fg_r $fg_g $fg_b),\
hl:$(printf '#%02x%02x%02x' $green),\
hl+:$(printf '#%02x%02x%02x' $green),\
gutter:$(printf '#%02x%02x%02x' $bg_r $bg_g $bg_b),\
info:$(printf '#%02x%02x%02x' $cyan),\
pointer:$(printf '#%02x%02x%02x' $green),\
marker:$(printf '#%02x%02x%02x' $green),\
spinner:$(printf '#%02x%02x%02x' $yellow),\
header:#505050,\
prompt:$(printf '#%02x%02x%02x' $cyan),\
border:$(printf '#%02x%02x%02x' $green),\
preview-bg:$(printf '#%02x%02x%02x' $bg_r $bg_g $bg_b),\
preview-fg:$(printf '#%02x%02x%02x' $fg2_r $fg2_g $fg2_b)"
                return
            fi
        fi
    fi

    # Fallback — use default palette
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'
    C_BD=$(_rgb $dgreen);   C_TL=$(_bold_rgb $dfg)
    C_LB=$(_rgb $dfg);      C_VL=$(_rgb $dyellow)
    C_ST=$(_rgb $dcyan);    C_TN=$(_rgb $dfg)
    C_PN=$(_rgb $dwhite)
    C_HL=$(_rgb $dyellow); C_ITA=$'\e[3m'
    local dbg_r dbg_g dbg_b dfg_r dfg_g dfg_b
    read -r dbg_r dbg_g dbg_b <<< "$dbg"
    read -r dfg_r dfg_g dfg_b <<< "$dfg"
    FZF_COLORS="\
bg:#282a36,bg+:#363849,\
fg:#e4e4e4,fg+:#f8f8f2,\
hl:$(printf '#%02x%02x%02x' $dgreen),\
hl+:$(printf '#%02x%02x%02x' $dgreen),\
gutter:#282a36,\
info:$(printf '#%02x%02x%02x' $dcyan),\
pointer:$(printf '#%02x%02x%02x' $dgreen),\
marker:$(printf '#%02x%02x%02x' $dgreen),\
spinner:$(printf '#%02x%02x%02x' $dyellow),\
header:#505050,\
prompt:$(printf '#%02x%02x%02x' $dcyan),\
border:$(printf '#%02x%02x%02x' $dgreen),\
preview-bg:#282a36,\
preview-fg:#e4e4e4"
}

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
_box_pane()   { printf "${C_BD}  │${C_RESET}  ${C_PN}     └ %-36s${C_RESET} ${C_BD}│${C_RESET}\n" "${1:0:36}"; }

# ── Preview builder (called from fzf --preview) ────────────────────
session_preview() {
    local item="$1"
    case "$item" in
        "── New Named ──")
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
    [[ -z "$item" ]] && { printf "${C_HL}  (session not found)${C_RESET}\n"; return; }
    session_info=$(zellij list-sessions -n 2>/dev/null \
        | awk -v item="$item" 'index($0, item " [Created") == 1 || index($0, item " (") == 1 {print; exit}' \
        || true)
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

    local tabs=() panes_by_tab=() pos_to_idx=()
    while IFS='|' read -r kind a b; do
        if [[ "$kind" == "tab" ]]; then
            local new_idx="${#tabs[@]}"
            pos_to_idx[$a]="$new_idx"
            tabs+=("$a|$b")
        elif [[ "$kind" == "pane" ]]; then
            local mapped_idx="${pos_to_idx[$a]:-0}"
            panes_by_tab[$mapped_idx]+="${b}, "
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

# ── ANSI helper ──────────────────────────────────────────────────────
_strip_ansi() { printf '%s' "$1" | sed $'s/\e\\[[0-9;]*m//g'; }

# ── Main ────────────────────────────────────────────────────────────
main() {
    _load_theme
    for cmd in zellij fzf; do
        command -v "$cmd" &>/dev/null || { echo "Error: $cmd required"; exit 1; }
    done

    local fzf_input="${C_ITA}── New Named ──${C_RESET}"$'\n'"${C_ITA}── New Untracked ──${C_RESET}"$'\n'"${C_ITA}── Resume ──${C_RESET}"$'\n'"${C_ITA}── Exit ──${C_RESET}"

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
              --header=' Ctrl-n:New  Ctrl-N:Named  Ctrl-r:Resume  Esc:Exit' \
              --header-first \
              --header-border=sharp \
              --color="${FZF_COLORS}" \
              --prompt='🔍 ' \
              --bind='ctrl-n:become(echo "── New Untracked ──")' \
              --bind='ctrl-N:become(echo "── New Named ──")' \
              --bind='ctrl-r:become(echo "── Resume ──")' \
              --preview="
                    $(for _v in C_RESET C_BOLD C_BD C_TL C_LB C_VL C_ST C_TN C_PN C_HL C_ITA; do printf '%s=%q; ' "$_v" "${!_v}"; done)
                    item={};
                    $(declare -f session_preview parse_metadata_file \
                                _box_top _box_sep _box_bot _box_title \
                                _box_label _box_line _box_tab _box_pane);
                    session_preview \"\$item\"
                " \
                --preview-window='right:60%:border-sharp' \
                --preview-label=' Session Details ' \
                --preview-label-pos=3
    )

    selected=$(_strip_ansi "$selected")
    case "$selected" in
        "── New Named ──")
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
            local resume_list
            resume_list=$(zellij list-sessions -n 2>/dev/null || true)
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
                        $(for _v in C_RESET C_BOLD C_BD C_TL C_LB C_VL C_ST C_TN C_PN C_HL C_ITA; do printf '%s=%q; ' "$_v" "${!_v}"; done)
                        item=\$(echo {} | sed 's/ \[Created.*//; s/ (.*//');
                        $(declare -f session_preview parse_metadata_file \
                                    _box_top _box_sep _box_bot _box_title \
                                    _box_label _box_line _box_tab _box_pane);
                        session_preview \"\$item\"
                    " \
                    --preview-window='right:60%:border-sharp' \
                    --preview-label=' Session Details ' \
                    --preview-label-pos=3
            )
            if [[ -n "$chosen" ]]; then
                local sname
                sname="$(echo "$chosen" | sed 's/ \[Created.*//; s/ (.*//')"
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