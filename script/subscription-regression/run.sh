#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
binary="$(mktemp -t headroom-subscription-tests)"
trap 'rm -f "$binary"' EXIT
swiftc "$here/../../HeadroomMac/Subscriptions/ClaudeUsageFeed.swift" "$here/main.swift" -o "$binary"
"$binary"
