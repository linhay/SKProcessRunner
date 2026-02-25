# iOS Build Check Runbook

## Purpose
Provide a stable local/CI command for validating SKProcessRunner compiles for iOS Simulator targets.

## Command
```bash
./scripts/check-ios-sim-build.sh
```

## Custom target triple
```bash
IOS_TRIPLE=arm64-apple-ios16.0-simulator ./scripts/check-ios-sim-build.sh
```

## Notes
- The script always resolves SDK via:
  - `xcrun --sdk iphonesimulator --show-sdk-path`
- This avoids mismatched sysroot/triple issues when using:
  - `swift build --triple ...` without an explicit `--sdk`.

