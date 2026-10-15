#!/usr/bin/env bats
# Core skeleton: CLI dispatch, version/feature helpers, config loader,
# name sanitizing and display-width utilities.

setup() {
  load test_helper
  jolt_setup
  jolt_source
}

@test "version" {
  run "$REPO/zellij-jolt.sh" --version
  assert_success
  assert_output "zellij-jolt 2.0.0"
}

@test "help lists the CLI" {
  run "$REPO/zellij-jolt.sh" --help
  assert_success
  assert_output --partial "--init-shell"
  assert_output --partial "--dry-run"
}

@test "unknown flag exits 2" {
  run "$REPO/zellij-jolt.sh" --bogus
  assert_failure 2
}

@test "not-yet-built flag dies without exec'ing a shell" {
  JOLT_NO_FALLBACK=1 run "$REPO/zellij-jolt.sh" --doctor
  assert_failure 1
  assert_output --partial "not implemented"
}

@test "JOLT_SELF is an absolute path to the script" {
  [ "$JOLT_SELF" = "$REPO/zellij-jolt.sh" ]
}

@test "ver_to_int" {
  run ver_to_int 0.74.5
  assert_output 74005
  run ver_to_int 0.38.0
  assert_output 38000
  run ver_to_int 4.2
  assert_output 4002000
}

@test "fzf_has gates on version" {
  FZF_VER=$(ver_to_int 0.62.0)
  fzf_has ghost
  fzf_has with-shell
  run fzf_has footer
  assert_failure
  run fzf_has header-border
  assert_failure
  run fzf_has bogus
  assert_failure
}

@test "sanitize" {
  run sanitize_name "  my  proj/x "
  assert_output "my-proj-x"
  run sanitize_name "   "
  assert_failure
  run sanitize_name $'a\x01b\tc'
  assert_output "ab-c"
}

@test "sanitize caps at 48 bytes on a char boundary" {
  run sanitize_name "$(printf 'a%.0s' {1..47})日本"
  assert_success
  [ "$output" = "$(printf 'a%.0s' {1..47})" ]
  run sanitize_name "$(printf 'b%.0s' {1..60})"
  [ "${#output}" -eq 48 ]
}

@test "dwidth" {
  run dwidth "abc"
  assert_output 3
  run dwidth "✳ ok"
  assert_output 4
  run dwidth "日本"
  assert_output 4
  run dwidth "🚀x"
  assert_output 3
  run dwidth $'é'
  assert_output 1
}

@test "pad and trunc" {
  run pad "日本語" 5
  assert_output "日本…" # width 4 + … = 5
  run pad "ab" 4
  assert_output "ab  "
  run trunc "abcdef" 4
  assert_output "abc…"
  run trunc "abcd" 4
  assert_output "abcd"
}

@test "config defaults" {
  config_load
  [ "$CFG_PROJECT_ROOTS" = "$HOME/projects $HOME/code $HOME/src $HOME/dev" ]
  [ "$CFG_PROJECT_DEPTH" = 3 ]
  [ "$CFG_DEFAULT_LAYOUT" = "" ]
  [ "$CFG_PREVIEW" = on ]
  [ "$CFG_THEME" = auto ]
  [ "$CFG_KEY_DELETE" = ctrl-d ]
  [ "$CFG_KEY_PREVIEW" = "ctrl-/" ]
  [ "$CFG_KEY_CREATE" = alt-enter ]
}

@test "config rejects injection and unknown keys" {
  mkdir -p "$XDG_CONFIG_HOME/zellij-jolt"
  printf 'DEFAULT_LAYOUT=compact\nEVIL=$(touch %s/pwned)\nPROJECT_ROOTS="~/a ~/b"\n' "$BATS_TEST_TMPDIR" >"$XDG_CONFIG_HOME/zellij-jolt/config"
  config_load 2>/dev/null
  [ "$CFG_DEFAULT_LAYOUT" = compact ]
  [ "$CFG_PROJECT_ROOTS" = "$HOME/a $HOME/b" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  run config_load
  assert_output --partial "EVIL"
}

@test "config value with command substitution is kept literally" {
  mkdir -p "$XDG_CONFIG_HOME/zellij-jolt"
  printf '# comment\n\nTHEME='"'"'$(touch %s/pwned)'"'"'\nKEY_PIN=ctrl-p\n' "$BATS_TEST_TMPDIR" >"$XDG_CONFIG_HOME/zellij-jolt/config"
  config_load 2>/dev/null
  [ "$CFG_THEME" = "\$(touch $BATS_TEST_TMPDIR/pwned)" ]
  [ "$CFG_KEY_PIN" = ctrl-p ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "init-shell zsh contains guards" {
  run "$REPO/zellij-jolt.sh" --init-shell zsh
  assert_success
  assert_output --partial '-z $ZELLIJ'
  assert_output --partial 'vscode'
  assert_output --partial 'exec zellij-jolt'
  assert_output --partial '-o interactive'
}

@test "init-shell bash and fish" {
  run "$REPO/zellij-jolt.sh" --init-shell bash
  assert_success
  assert_output --partial '$- == *i*'
  run "$REPO/zellij-jolt.sh" --init-shell fish
  assert_success
  assert_output --partial 'status is-interactive'
  run "$REPO/zellij-jolt.sh" --init-shell tcsh
  assert_failure 2
}
