#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="${HEADROOM_SUBSCRIPTION_TEST_ROOT:-${TMPDIR:-/tmp}}"
work="$(mktemp -d "$root/headroom-subscription-tests.XXXXXX")"
cleanup() {
  # Permission-failure fixtures must remain removable even if an assertion aborts.
  # find does not follow symlinks; only directories inside this owned temp tree change.
  find "$work" -type d -exec chmod u+rwx {} \;
  rm -rf "$work"
}
trap cleanup EXIT
mkdir "$work/module-cache"
TMPDIR="$work" CLANG_MODULE_CACHE_PATH="$work/module-cache" \
  swiftc -module-cache-path "$work/module-cache" \
  "$here/../../HeadroomMac/Subscriptions/ClaudeUsageFeed.swift" "$here/main.swift" -o "$work/tests"
HEADROOM_SUBSCRIPTION_TEST_ROOT="$work/homes" "$work/tests"
