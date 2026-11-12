#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/edgeshift-display-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
sources=()
for source_file in Sources/EdgeShift/*.swift; do
    if [[ "$source_file" != */EdgeShiftApp.swift ]]; then
        sources+=("$source_file")
    fi
done
swiftc -D EDGESHIFT_STANDALONE "${sources[@]}" \
    Tests/EdgeShiftTests/DisplayModeChecks.swift scripts/test-display-modes.swift -o "$test_dir/checks"
"$test_dir/checks"
