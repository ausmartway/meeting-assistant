#!/usr/bin/env bash
# Run the test suite under Command Line Tools (no full Xcode).
#
# The swift-testing `Testing` framework ships inside the Command Line Tools at a
# path that SwiftPM does not search by default, so we add it explicitly. When the
# project is opened in full Xcode this script is unnecessary — `swift test` (or
# Cmd-U) finds the framework automatically.
set -euo pipefail

FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
# Testing.framework links against lib_TestingInterop.dylib, which lives in a
# sibling lib dir that is not on the default runtime search path.
INTEROP_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [[ ! -d "$FW" ]]; then
  echo "Testing.framework not found at $FW — run under full Xcode with 'swift test'." >&2
  exit 1
fi

exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$INTEROP_LIB" \
  "$@"
