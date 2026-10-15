# shellcheck shell=bash
#
# Shared bats setup for the zellij-jolt test suite. Load from each .bats
# file's own `setup()` with `load test_helper` and then call `jolt_setup`.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO

load "$REPO/test/lib/bats-support/load.bash"
load "$REPO/test/lib/bats-assert/load.bash"

# jolt_setup — call from the test file's setup(). Builds an isolated
# XDG/zellij-jolt environment under $BATS_TEST_TMPDIR, puts the zellij stub
# first on PATH, and seeds the cache dir with the session_info fixtures.
jolt_setup() {
  mkdir -p "$BATS_TEST_TMPDIR/config" "$BATS_TEST_TMPDIR/state" "$BATS_TEST_TMPDIR/cache"

  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export JOLT_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
  export JOLT_ZELLIJ_CONFIG="$BATS_TEST_TMPDIR/zellij.kdl"
  export JOLT_NOW=1760000000
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  export STUB_LS=""

  : >"$STUB_LOG"

  PATH="$REPO/test/stubs:$PATH"
  export PATH

  cp -r "$REPO/test/fixtures/session_info/." "$JOLT_CACHE_DIR/"

  unset ZELLIJ ZELLIJ_SESSION_NAME NO_COLOR
}

# jolt_source — source zellij-jolt.sh with JOLT_NO_MAIN=1 so only its
# functions are defined (no picker/main dispatch runs). Not used by
# infra.bats: the script doesn't support JOLT_NO_MAIN yet.
jolt_source() {
  JOLT_NO_MAIN=1 source "$REPO/zellij-jolt.sh"
}

# use_ls NAME — point the zellij stub's `list-sessions`/`ls` output at
# test/fixtures/ls/NAME.txt.
use_ls() {
  export STUB_LS="$REPO/test/fixtures/ls/$1.txt"
}

# use_cfg NAME — copy test/fixtures/config/NAME.kdl to $JOLT_ZELLIJ_CONFIG.
use_cfg() {
  cp "$REPO/test/fixtures/config/$1.kdl" "$JOLT_ZELLIJ_CONFIG"
}
