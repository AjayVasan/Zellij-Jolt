#!/usr/bin/env bash
# Run the zellij-jolt bats test suite.
#
# Usage:
#   test/run.sh                 # run every .bats file under test/
#   test/run.sh test/foo.bats   # run specific file(s)/dir(s)
exec "$(dirname "$0")/lib/bats-core/bin/bats" "${@:-$(dirname "$0")}"
