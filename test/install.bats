#!/usr/bin/env bats
# Tests for install.sh: XDG install/uninstall, dependency + version-floor
# checks, multi-terminal hook snippets, and safe (opt-in, non-destructive)
# GNOME shortcut registration.
#
# Every test runs with an isolated $HOME, XDG_DATA_HOME/XDG_BIN_HOME/
# XDG_CURRENT_DESKTOP unset, and a PATH that starts with
# test/stubs/install (gsettings/zellij/fzf/terminal stubs) so this suite
# never touches the real ~/.local or a real gsettings/desktop.

setup() {
  load test_helper

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"

  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  export STUB_DIR
  mkdir -p "$STUB_DIR"
  for bin in gsettings zellij fzf alacritty; do
    cp "$REPO/test/stubs/install/$bin" "$STUB_DIR/$bin"
    chmod +x "$STUB_DIR/$bin"
  done

  GSET_LOG="$BATS_TEST_TMPDIR/gsettings.log"
  export GSET_LOG
  : >"$GSET_LOG"

  PATH="$STUB_DIR:$PATH"
  export PATH
}

# add_stub NAME — copy another test/stubs/install binary (e.g. a second
# terminal) onto $STUB_DIR, for tests that need more than the default set.
add_stub() {
  cp "$REPO/test/stubs/install/$1" "$STUB_DIR/$1"
  chmod +x "$STUB_DIR/$1"
}

run_install() {
  run env -u XDG_DATA_HOME -u XDG_BIN_HOME -u XDG_CURRENT_DESKTOP \
    bash "$REPO/install.sh" "$@"
}

# ── install / uninstall ──────────────────────────────────────────────

@test "install --yes works with XDG_CURRENT_DESKTOP unset" {
  run_install --yes
  assert_success
  [ -L "$HOME/.local/bin/zellij-jolt" ]
  [ -e "$HOME/.local/share/zellij-jolt/zellij-jolt.sh" ]
}

@test "install --yes is non-interactive even on stdin (no hang, no prompt text left dangling)" {
  run_install --yes < /dev/null
  assert_success
}

@test "non-tty stdin behaves like --yes with no flags at all" {
  # No --yes, no XDG_CURRENT_DESKTOP(GNOME); bats' `run` never gives the
  # child a tty, so this must still complete without blocking on a prompt.
  run_install
  assert_success
  [ -L "$HOME/.local/bin/zellij-jolt" ]
}

@test "install into an unwritable target exits 1 with an error and no checkmark" {
  mkdir -p "$BATS_TEST_TMPDIR/ro"
  chmod 555 "$BATS_TEST_TMPDIR/ro"
  run env -u XDG_CURRENT_DESKTOP XDG_DATA_HOME="$BATS_TEST_TMPDIR/ro/share" \
    XDG_BIN_HOME="$BATS_TEST_TMPDIR/ro/bin" bash "$REPO/install.sh" --yes
  chmod 755 "$BATS_TEST_TMPDIR/ro"
  assert_failure 1
  assert_output --partial "Error:"
  refute_output --partial "✓"
}

@test "install exits 1 when only the bin dir is unwritable (symlink step fails)" {
  mkdir -p "$BATS_TEST_TMPDIR/robin"
  chmod 555 "$BATS_TEST_TMPDIR/robin"
  run env -u XDG_CURRENT_DESKTOP XDG_DATA_HOME="$BATS_TEST_TMPDIR/share" \
    XDG_BIN_HOME="$BATS_TEST_TMPDIR/robin" bash "$REPO/install.sh" --yes
  chmod 755 "$BATS_TEST_TMPDIR/robin"
  assert_failure 1
  assert_output --partial "could not create the symlink"
  refute_output --partial "✓"
}

@test "uninstall removes the symlink and install dir" {
  run_install --yes
  assert_success

  run_install --uninstall
  assert_success
  [ ! -e "$HOME/.local/bin/zellij-jolt" ]
  [ ! -e "$HOME/.local/share/zellij-jolt" ]
}

@test "uninstall prints that it does not touch shortcuts/terminal config" {
  run_install --yes
  run_install --uninstall
  assert_success
  assert_output --partial "did not touch"
}

@test "--help prints usage and exits 0 without installing" {
  run_install --help
  assert_success
  assert_output --partial "Usage"
  [ ! -e "$HOME/.local/bin/zellij-jolt" ]
}

@test "unknown flag exits non-zero with usage" {
  run_install --bogus
  assert_failure
  assert_output --partial "Usage"
}

# ── dependency + version-floor checks ────────────────────────────────

@test "missing required dependency prints a package-manager hint" {
  # A PATH with only coreutils + gsettings/alacritty (no zellij/fzf
  # anywhere, including /usr/bin, which on this box has real copies of
  # both), plus pacman already on this dev box, so the hint names it.
  rm -f "$STUB_DIR/zellij" "$STUB_DIR/fzf"

  CORE_DIR="$BATS_TEST_TMPDIR/core"
  mkdir -p "$CORE_DIR"
  local bin
  for bin in bash mkdir cp chmod ln rm grep sort mv cat basename dirname tr head pacman env; do
    [ -x "/usr/bin/$bin" ] && ln -sf "/usr/bin/$bin" "$CORE_DIR/$bin"
  done

  PATH="$STUB_DIR:$CORE_DIR"
  export PATH
  run_install --yes
  assert_output --partial "pacman"
}

@test "below-floor zellij version prints a warning but still installs" {
  STUB_ZELLIJ_VERSION=0.30.0 run_install --yes
  assert_success
  assert_output --partial "0.30.0"
  [ -L "$HOME/.local/bin/zellij-jolt" ]
}

@test "below-floor fzf version prints a warning but still installs" {
  STUB_FZF_VERSION="0.20.0 (debug)" run_install --yes
  assert_success
  assert_output --partial "0.20.0"
}

@test "at-floor versions print no warning" {
  STUB_ZELLIJ_VERSION=0.45.1 STUB_FZF_VERSION="0.74.5 (abc)" run_install --yes
  assert_success
  refute_output --partial "older than"
}

# ── terminal hook snippets ────────────────────────────────────────────

@test "prints alacritty snippet" {
  run_install --yes
  assert_output --partial '[terminal]'
  assert_output --partial 'shell = "'
}

@test "prints kitty snippet when kitty is present" {
  add_stub kitty
  rm -f "$STUB_DIR/alacritty"
  run_install --yes
  assert_output --partial 'shell '
  assert_output --partial "$HOME/.local/bin/zellij-jolt"
}

@test "prints ghostty snippet when ghostty is present" {
  add_stub ghostty
  rm -f "$STUB_DIR/alacritty"
  run_install --yes
  assert_output --partial 'command = '
}

@test "prints wezterm snippet when wezterm is present" {
  add_stub wezterm
  rm -f "$STUB_DIR/alacritty"
  run_install --yes
  assert_output --partial 'config.default_prog = { "'
}

@test "prints foot snippet when foot is present" {
  add_stub foot
  rm -f "$STUB_DIR/alacritty"
  run_install --yes
  assert_output --partial '[main]'
  assert_output --partial 'shell='
}

@test "prints snippets for every detected terminal, not just the first" {
  add_stub kitty
  run_install --yes
  assert_output --partial '[terminal]'
  assert_output --partial 'shell '
}

@test "prints the --init-shell hint as the alternative" {
  run_install --yes
  assert_output --partial '--init-shell'
}

@test "PATH hint prints BIN_DIR when BIN_DIR is not on PATH" {
  PATH="$STUB_DIR:/usr/bin:/bin"
  export PATH
  run_install --yes
  assert_output --partial "$HOME/.local/bin"
}

# ── GNOME shortcut: opt-in gate ───────────────────────────────────────

@test "no gsettings writes with --yes" {
  XDG_CURRENT_DESKTOP=ubuntu:GNOME run bash "$REPO/install.sh" --yes
  run grep -c ' set ' "$GSET_LOG"
  assert_output 0
}

@test "no gsettings writes at all when desktop is not GNOME" {
  run_install --yes
  run grep -c . "$GSET_LOG"
  assert_output 0
}

@test "--no-shortcut suppresses the GNOME prompt/writes even on GNOME" {
  XDG_CURRENT_DESKTOP=GNOME run bash "$REPO/install.sh" --no-shortcut
  run grep -c . "$GSET_LOG"
  assert_output 0
}

@test "non-tty stdin on GNOME never writes a shortcut (behaves like --yes)" {
  XDG_CURRENT_DESKTOP=GNOME run bash "$REPO/install.sh"
  run grep -c . "$GSET_LOG"
  assert_output 0
}

@test "GNOME detection matches compound XDG_CURRENT_DESKTOP values" {
  XDG_CURRENT_DESKTOP=ubuntu:GNOME run bash "$REPO/install.sh" --yes
  assert_success
}

# ── GNOME shortcut: internal duplicate-scan logic (unit-level) ───────
# These source install.sh with JOLT_INSTALL_NO_MAIN=1 so only its
# functions are defined (no arg parsing, no install, no prompts run),
# then exercise the gsettings helpers directly. This is the only way to
# cover the actual registration/duplicate-scan path, since --yes and
# non-tty stdin (both true under `run`) always skip it end-to-end.

jolt_install_source() {
  JOLT_INSTALL_NO_MAIN=1 source "$REPO/install.sh"
}

@test "gsettings_next_custom_path picks custom0 when list is empty" {
  jolt_install_source
  export GSET_EXISTING="@as []"
  run gsettings_next_custom_path
  assert_success
  assert_output "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
}

@test "gsettings_next_custom_path scans the whole list, not just its length" {
  jolt_install_source
  # Only custom1 is taken; a naive by-count scan (len==1 => next is
  # custom1) would collide. The real scan must notice custom0 is free.
  export GSET_EXISTING="['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/']"
  run gsettings_next_custom_path
  assert_success
  assert_output "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
}

@test "gsettings_next_custom_path skips every taken slot" {
  jolt_install_source
  export GSET_EXISTING="['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/', '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/']"
  run gsettings_next_custom_path
  assert_success
  assert_output "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom2/"
}

@test "gsettings_register_shortcut writes name/binding/command and extends the list" {
  jolt_install_source
  export GSET_EXISTING="['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']"
  gsettings_register_shortcut "zellij-jolt" "<Control>Return" "/bin/zellij-jolt"

  local sep
  sep="$(printf '\x1f')"
  run grep -c "custom-keybinding:.*custom1/${sep}name${sep}zellij-jolt" "$GSET_LOG"
  assert_output 1
  run grep -c "custom-keybinding:.*custom1/${sep}binding${sep}<Control>Return" "$GSET_LOG"
  assert_output 1
  run grep -c "custom-keybinding:.*custom1/${sep}command${sep}/bin/zellij-jolt" "$GSET_LOG"
  assert_output 1
  run grep -c "custom-keybindings${sep}\[.*custom0/.*custom1/" "$GSET_LOG"
  assert_output 1
}

# ── GNOME shortcut: terminal wrapping (a shortcut has no tty) ─────────

@test "GNOME shortcut command is wrapped in the first terminal found (alacritty)" {
  jolt_install_source
  export GSET_EXISTING="@as []"
  YES=0 NO_SHORTCUT=0 XDG_CURRENT_DESKTOP=GNOME BIN_DIR=/opt/bin
  run maybe_register_gnome_shortcut <<<"y"
  assert_success
  local sep
  sep="$(printf '\x1f')"
  run grep -c "custom-keybinding:.*custom0/${sep}command${sep}alacritty -e /opt/bin/zellij-jolt${sep}" "$GSET_LOG"
  assert_output 1
}

@test "gnome_shortcut_command uses each terminal's own exec syntax" {
  jolt_install_source
  local t d expect
  for t in kitty wezterm ghostty foot gnome-terminal; do
    d="$BATS_TEST_TMPDIR/only-$t"
    mkdir -p "$d"
    printf '#!/bin/sh\nexit 0\n' >"$d/$t"
    chmod +x "$d/$t"
    case $t in
      kitty) expect="kitty /b/zellij-jolt" ;;
      wezterm) expect="wezterm start -- /b/zellij-jolt" ;;
      ghostty) expect="ghostty -e /b/zellij-jolt" ;;
      foot) expect="foot /b/zellij-jolt" ;;
      gnome-terminal) expect="gnome-terminal -- /b/zellij-jolt" ;;
    esac
    PATH="$d" run gnome_shortcut_command /b/zellij-jolt
    assert_success
    assert_output "$expect"
  done
}

@test "GNOME shortcut is skipped with a message when no terminal is on PATH" {
  jolt_install_source
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  YES=0 NO_SHORTCUT=0 XDG_CURRENT_DESKTOP=GNOME
  PATH="$BATS_TEST_TMPDIR/empty" run maybe_register_gnome_shortcut <<<"y"
  assert_success
  assert_output --partial "No supported terminal emulator found"
  run grep -c . "$GSET_LOG"
  assert_output 0
}
