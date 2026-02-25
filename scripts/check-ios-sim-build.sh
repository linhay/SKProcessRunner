#!/usr/bin/env bash
set -euo pipefail

# Build SKProcessRunner for iOS Simulator with explicit SDK.
# This avoids the common "using sysroot for 'MacOSX' but targeting 'iPhone'" pitfall.

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found. Install Xcode command line tools first." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift not found." >&2
  exit 1
fi

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TRIPLE="${IOS_TRIPLE:-arm64-apple-ios14.0-simulator}"

echo "Using SDK: ${SDK_PATH}"
echo "Using triple: ${TRIPLE}"

swift build \
  --sdk "${SDK_PATH}" \
  --triple "${TRIPLE}"

echo "iOS simulator build check passed."

