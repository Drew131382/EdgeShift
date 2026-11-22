#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/edgeshift-ripple-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
swiftc Sources/EdgeShift/Geometry.swift Sources/EdgeShift/RippleAnimation.swift \
    Sources/EdgeShift/RippleShader.swift scripts/test-ripple.swift -o "$test_dir/checks"
"$test_dir/checks" "$@"
