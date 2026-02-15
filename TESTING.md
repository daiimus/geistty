# Testing Guide for Geistty

This document explains how to build, test, and debug Geistty.

## Quick Start

```bash
cd Geistty

# Build for simulator (no signing required)
./ci.sh build

# Run unit tests
./ci.sh test

# Run all CI checks (build + lint)
./ci.sh all
```

## CI Script Commands

The `ci.sh` script provides automated build and test capabilities:

| Command | Description |
|---------|-------------|
| `./ci.sh build` | Build for iOS Simulator (no code signing) |
| `./ci.sh device-build` | Build for iOS device (requires signing) |
| `./ci.sh install [DEVICE_ID]` | Install and launch on device |
| `./ci.sh test` | Run unit tests on simulator |
| `./ci.sh ui-test` | Run UI tests on simulator |
| `./ci.sh lint` | Analyze code for warnings |
| `./ci.sh all` | Run all CI checks |
| `./ci.sh sync-ghostty` | Sync GhosttyKit xcframework from ghostty repo |

## Building Without Code Signing

For CI/automation, you can build without signing using the simulator:

```bash
xcodebuild build \
    -project Geistty.xcodeproj \
    -scheme Geistty \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
    CODE_SIGNING_ALLOWED=NO
```

## Test Targets

### GeisttyTests (Unit Tests)
- Tests core logic without UI or network dependencies
- Files in `GeisttyTests/`
- Run with: `./ci.sh test`
- **401 tests** across 20 test suites in 15 test files, all passing
- No mocks — direct unit tests of real implementations
- Auth module tests use real Keychain on simulator (cleaned up in tearDown)

### GeisttyUITests (UI Tests)
- Requires a running app instance
- Tests user-facing interactions
- Run with: `./ci.sh ui-test`

## Test Files

| File | Tests | Purpose |
|------|-------|---------|
| `TmuxProtocolParserTests.swift` | 80 | tmux control mode protocol parsing: %output, %begin/%end, blocks, octal escapes, fragmented data |
| `KittyKeyboardTranslatorTests.swift` | 64 | Kitty keyboard protocol → legacy terminal escape sequence translation |
| `TmuxSplitTreeTests.swift` | 63 | Split tree structure: factory from layout, queries, zoom, equalize, ratio updates, Codable round-trip |
| `GhosttyInputTests.swift` | 44 | Hardware keyboard input handling, Ctrl+key combos, modifier processing |
| `TmuxModelsTests.swift` | 36 | tmux session/window/pane parsing, ID validation, numeric extraction, Equatable |
| `TmuxLayoutTests.swift` | 32 | tmux layout string parsing, checksum calculation, error cases, convenience properties |
| `FontMappingTests.swift` | 31 | Font name mapping between GUI display names and Ghostty/CoreText names |
| `ConnectionProfileTests.swift` | 19 | SSH connection profile serialization, auth methods, display strings |

## Test Pattern

All tests follow the same pattern:

```swift
import XCTest
@testable import Geistty

final class SomethingTests: XCTestCase {
    // Optional setUp with implicitly unwrapped optionals
    // // MARK: - sections to organize
    // Private helper methods in // MARK: - Helpers
    // No mocks — direct unit tests of real implementations
}
```

## Running Tests

```bash
# Quick test run
cd Geistty && ./ci.sh test

# Direct xcodebuild command
xcodebuild test -project Geistty.xcodeproj -scheme Geistty \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
    -only-testing:GeisttyTests

# Full log available at
cat /tmp/geistty_tests.log
```

## Device Testing

### Find Connected Devices
```bash
xcrun devicectl list devices
```

### Build and Deploy
```bash
# Build
xcodebuild -project Geistty.xcodeproj -scheme Geistty \
    -destination "id=DEVICE_ID" -allowProvisioningUpdates build

# Install
xcrun devicectl device install app --device DEVICE_ID \
    ~/Library/Developer/Xcode/DerivedData/Geistty-*/Build/Products/Debug-iphoneos/Geistty.app

# Launch with console output
xcrun devicectl device process launch --device DEVICE_ID --console com.geistty.app
```

### Viewing Device Logs
```bash
# Launch with console (streams logs in real-time)
xcrun devicectl device process launch --device DEVICE_ID --console com.geistty.app

# Filter for specific categories
xcrun devicectl device process launch --device DEVICE_ID --console com.geistty.app 2>&1 | \
    grep -E "(SSH|Terminal|tmux|capture)" --line-buffered
```

## Known Device IDs

| Device | UDID | CoreDevice UUID |
|--------|------|-----------------|
| ICarus (iPad Pro) | `00008103-001425D11153001E` | `4E8A6D04-FCF9-5BB5-BF57-22080EC6A31A` |
| Athena (iPhone) | `00008130-001049E23ED0001C` | `55CF3503-DC69-50E1-BC33-17A7DB9ECE9C` |

## Build Artifacts

| Path | Contents |
|------|----------|
| `~/Library/Developer/Xcode/DerivedData/Geistty-*/` | Build outputs |
| `/tmp/geistty_build.log` | Full build log |
| `/tmp/geistty_tests.log` | Full test log |

## Agent Development Notes

When working as a coding agent:

1. **Always run `./ci.sh build` after code changes** to verify compilation
2. **Run `./ci.sh test` after adding/modifying tests** to verify they pass
3. **Check `/tmp/geistty_build.log` for full error details** if build fails
4. **Use simulator builds** for quick iteration (no signing delays)
5. **Device testing** requires user to verify behavior on ICarus/Athena
6. **New test files** must be added to `project.pbxproj` (PBXBuildFile, PBXFileReference, GeisttyTests group, test target Sources build phase)
