#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/release.py validate
test_args=(--scratch-path "${AWAKE_BUILD_DIR:-$HOME/Library/Developer/Awake/Build}" --arch arm64 --disable-xctest)
testing_plugin="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$testing_plugin" ]]; then
    test_args+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
swift test "${test_args[@]}"
python3 -m unittest discover -s Tests -p 'test_*.py'
