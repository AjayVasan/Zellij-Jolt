#!/usr/bin/env bats
# Theme loader: zellij theme resolution (inline themes{} block, theme_dir
# files), legacy RGB / hex / component palette formats, fallbacks.
# Fixtures all use fg 244 244 244 (#f4f4f4) and bg 24 24 24 (#181818).

setup() {
  load test_helper
  jolt_setup
  jolt_source
}

@test "no theme line → terminal default" {
  use_cfg none
  theme_load
  [[ $JOLT_THEME_DESC == "terminal default" ]]
  [[ $FZF_COLOR_OPT == 16* ]]
  [[ $C_ACCENT == $'\e[32m' ]]
  [[ $C_RESET == $'\e[0m' ]]
}

@test "legacy rgb" {
  use_cfg legacy
  theme_load
  [[ $JOLT_THEME_DESC == "gruber-darker (legacy palette)" ]]
  [[ $FZF_COLOR_OPT == *"bg:#181818"* ]]
  [[ $FZF_COLOR_OPT == *"fg+:#f4f4f4"* ]]
  [[ $FZF_COLOR_OPT == *"bg+:#3a3a3a"* ]]
  [[ $FZF_COLOR_OPT == *"hl:#73d936"* ]]
  [[ $FZF_COLOR_OPT == *"prompt:#95a99f"* ]]
  [[ $FZF_COLOR_OPT == *"header:#747474"* ]]
  [[ $C_ACCENT == $'\e[38;2;115;217;54m' ]]
  [[ $C_OK == $'\e[38;2;115;217;54m' ]]
  [[ $C_WARN == $'\e[38;2;255;221;126m' ]]
  [[ $C_MUTED == $'\e[38;2;116;116;116m' ]]
  [[ $C_TITLE == $'\e[1;38;2;244;244;244m' ]]
}

@test "hex" {
  use_cfg hex
  theme_load
  [[ $JOLT_THEME_DESC == gruber-darker-hex* ]]
  [[ $FZF_COLOR_OPT == *"fg+:#f4f4f4"* ]]
  [[ $FZF_COLOR_OPT == *"bg:#181818"* ]]
  [[ $FZF_COLOR_OPT == *"hl:#73d936"* ]]
}

@test "component format" {
  use_cfg component
  theme_load
  [[ $JOLT_THEME_DESC == *component* ]]
  [[ $JOLT_THEME_DESC == *"(component format)" ]]
  [[ $FZF_COLOR_OPT == *"bg:#181818"* ]]
  [[ $FZF_COLOR_OPT == *"fg+:#f4f4f4"* ]]
  # accent from frame_selected base, ok from exit_code_success
  [[ $C_ACCENT == $'\e[38;2;255;221;126m' ]]
  [[ $C_OK == $'\e[38;2;115;217;54m' ]]
  [[ $C_WARN == $'\e[38;2;255;221;126m' ]]
}

@test "theme_dir" {
  sed "s|@DIR@|$REPO/test/fixtures/themes|" "$REPO/test/fixtures/config/themedir.kdl" >"$JOLT_ZELLIJ_CONFIG"
  theme_load
  [[ $JOLT_THEME_DESC == mytheme* ]]
  [[ $FZF_COLOR_OPT == *"bg:#181818"* ]]
}

@test "default theme_dir is next to the config file" {
  mkdir -p "$BATS_TEST_TMPDIR/themes"
  cp "$REPO/test/fixtures/themes/mytheme.kdl" "$BATS_TEST_TMPDIR/themes/other-name.kdl"
  printf 'theme "mytheme"\n' >"$JOLT_ZELLIJ_CONFIG"
  theme_load
  [[ $JOLT_THEME_DESC == mytheme* ]]
  [[ $FZF_COLOR_OPT == *"bg:#181818"* ]]
}

@test "NO_COLOR" {
  use_cfg legacy
  NO_COLOR=1 theme_load
  [ -z "$C_ACCENT" ]
  [ -z "$C_RESET" ]
  [[ $JOLT_THEME_DESC == none ]]
  [[ $FZF_COLOR_OPT == bw ]]
}

@test "THEME=none is colorless" {
  use_cfg legacy
  CFG_THEME=none theme_load
  [ -z "$C_OK" ]
  [[ $JOLT_THEME_DESC == none ]]
}

@test "CFG_THEME overrides the config theme name" {
  use_cfg legacy
  sed -i 's/^themes {/themes {\n    other { fg "#010203"; bg "#040506"; green 1 2 3; }/' "$JOLT_ZELLIJ_CONFIG"
  CFG_THEME=other theme_load
  [[ $JOLT_THEME_DESC == "other (legacy palette)" ]]
  [[ $FZF_COLOR_OPT == *"bg:#040506"* ]]
}

@test "missing config file" {
  rm -f "$JOLT_ZELLIJ_CONFIG"
  run theme_load
  assert_success
  theme_load
  [[ $JOLT_THEME_DESC == "terminal default" ]]
}

@test "unknown theme name → terminal default" {
  printf 'theme "dracula"\n' >"$JOLT_ZELLIJ_CONFIG"
  theme_load
  [[ $JOLT_THEME_DESC == "terminal default"* ]]
  [[ $FZF_COLOR_OPT == 16* ]]
}

@test "comments are ignored" {
  cat >"$JOLT_ZELLIJ_CONFIG" <<'EOF'
// theme "commented"
/* theme "blocked"
   themes { blocked { fg 1 1 1 } } */
themes { // trailing comment with "quote {"
    real {
        fg 244 244 244 // comment
        bg "#181818" /* inline */; green 115 217 54
        /- red 1 2 3
    }
    /-ghost {
        fg 1 1 1
    }
}
theme "real" // pick real
EOF
  theme_load
  [[ $JOLT_THEME_DESC == "real (legacy palette)" ]]
  [[ $FZF_COLOR_OPT == *"bg:#181818"* ]]
  [[ $FZF_COLOR_OPT == *"hl:#73d936"* ]]
}

@test "bad tokens and 256-index colors are skipped under set -u" {
  cat >"$JOLT_ZELLIJ_CONFIG" <<'EOF'
themes {
    t {
        fg 244 244 244
        bg 24 24 24
        green 115 217 54
        red 123
        blue "#zzzzzz"
        cyan 300 1 1
        yellow
        }}}}
    }
}
theme "t"
EOF
  run bash -c 'set -u; JOLT_NO_MAIN=1 source "$REPO/zellij-jolt.sh"; theme_load; printf "%s\n" "$JOLT_THEME_DESC"'
  assert_success
  assert_output "t (legacy palette)"
}

@test "theme without fg/bg is unparsable → terminal default" {
  printf 'themes {\n    t {\n        red 1 2 3\n    }\n}\ntheme "t"\n' >"$JOLT_ZELLIJ_CONFIG"
  theme_load
  [[ $JOLT_THEME_DESC == "terminal default"* ]]
  [[ $FZF_COLOR_OPT == 16* ]]
}

@test "braces and escaped quotes inside strings do not break block depth" {
  cat >"$JOLT_ZELLIJ_CONFIG" <<'EOF'
keybinds {
    normal {
        bind "{" { SwitchToMode "Normal"; }
        bind "Alt }" "x\"}" { Run "echo" "}}}" "a // b"; }
    }
}
themes {
    t { fg 244 244 244; bg 24 24 24; green 115 217 54; }
}
theme "t"
EOF
  theme_load
  [[ $JOLT_THEME_DESC == "t (legacy palette)" ]]
  [[ $FZF_COLOR_OPT == *"bg:#181818"* ]]
}
