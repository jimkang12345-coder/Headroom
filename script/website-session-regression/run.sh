#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/headroom-website-session-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
swift build --package-path "$root/HeadroomCore" --scratch-path "$work/build" >/dev/null
bin="$(swift build --package-path "$root/HeadroomCore" --scratch-path "$work/build" --show-bin-path)"
if [[ -f "$bin/libHeadroomCore.a" ]]; then
    module_dir="$bin"
    core_inputs=("$bin/libHeadroomCore.a")
else
    module_dir="$bin/Modules"
    core_inputs=("$bin"/HeadroomCore.build/*.o)
fi
swiftc -parse-as-library -I "$module_dir" \
    "$root/HeadroomMac/Subscriptions/ClaudeWebsiteClient.swift" \
    "$here/RegressionMain.swift" "${core_inputs[@]}" \
    -framework AppKit -framework WebKit -o "$work/regression"
"$work/regression"
