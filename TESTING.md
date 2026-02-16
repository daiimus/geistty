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
- **550 tests** across 20 test files (22 including mocks), all passing
- Mock-based tests for tmux lifecycle (`MockTmuxSurface`, `MockSSHSessionDelegate`)
- Auth module tests use real Keychain on simulator (cleaned up in tearDown)

### GeisttyUITests (UI Tests)
- Requires a running app instance
- Tests user-facing interactions
- Run with: `./ci.sh ui-test`

## Test Files

### Unit Tests (20 files + 2 mocks, 550 tests across 25 suites)

| File | Tests | Purpose |
|------|-------|---------|
| `TmuxSplitTreeTests.swift` | 63 | Split tree structure: factory from layout, queries, zoom, equalize, ratio updates, Codable round-trip |
| `TmuxWireDiagnosticsTests.swift` | 48 | Shadow parser for tmux control mode wire data, octal escaping, message parsing |
| `TmuxSessionManagerTests.swift` | 45 | Command formatting, state transitions, handleTmuxStateChanged with mock surface, cleanup, zoom/equalize/resize, removeSurface |
| `GhosttyInputTests.swift` | 44 | Hardware keyboard input handling, Ctrl+key combos, modifier processing |
| `TmuxSessionNameResolverTests.swift` | 35 | Session discovery, name resolution |
| `TmuxLayoutTests.swift` | 32 | tmux layout string parsing, checksum calculation, error cases, convenience properties |
| `FontMappingTests.swift` | 31 | Font name mapping between GUI display names and Ghostty/CoreText names |
| `CommandPaletteTests.swift` | 30 | Command palette search, filtering, action execution |
| `TmuxViewerReadyTests.swift` | 29 | Viewer ready gating, write routing |
| `TmuxStateReconciliationTests.swift` | 22 | reconcileTmuxState() pure logic, focused-pane-from-tmux vs fallback-to-first |
| `SSHKeyParserTests.swift` | 20 | SSH key format parsing (Ed25519, RSA, ECDSA), PEM/OpenSSH formats, PKCS#8 |
| `ConnectionProfileTests.swift` | 19 | SSH connection profile serialization, auth methods, display strings |
| `ConfigSyncThemeTests.swift` | 19 | Config sync theme resolution and persistence |
| `ConfigIntrospectionTests.swift` | 18 | ghostty_config_get() introspection for supported types |
| `TmuxModelsTests.swift` | 14 | tmux session/window/pane parsing, ID validation, numeric extraction, Equatable |
| `TmuxConnectionLifecycleTests.swift` | 14 | tmux notification-driven lifecycle: state changes, pane activation, flush, exit/reactivate (uses MockTmuxSurface + MockSSHSessionDelegate) |
| `ResizeTimingTests.swift` | 14 | Terminal resize debouncing and timing |
| `SSHKeyManagerTests.swift` | 11 | Key generation, import, round-trip validation via real CryptoKit |
| `TmuxDataFlowTests.swift` | 10 | SSH data ingress: delegate forwarding, early buffering, delegate flush, discovery interception, DCS chunk boundary |
| `KeychainManagerTests.swift` | 12 | Keychain CRUD operations (real Keychain on simulator, cleaned up in tearDown) — split across KeychainManagerPasswordTests (8), KeychainManagerSSHKeyTests (9), KeychainErrorTests (3), SSHKeyPairTests (4), SSHKeyErrorTests (2), SSHKeyTypeTests (6) |

### Mock Helpers (2 files)

| File | Purpose |
|------|---------|
| `MockTmuxSurface.swift` | Implements `TmuxSurfaceProtocol` with stubbed C API returns and call tracking |
| `MockSSHSessionDelegate.swift` | Implements `SSHSessionDelegate` for lifecycle testing without real SSH |

### UI Tests (4 files)

| File | Purpose |
|------|---------|
| `GeisttyUITests.swift` | Basic app launch and navigation |
| `ConnectedTests.swift` | Connected terminal state |
| `TmuxPaneUITests.swift` | tmux pane interactions |
| `TmuxSizingDebugTests.swift` | tmux pane sizing diagnostics |

### tmux Test Coverage Summary

| Test File | Tests | What It Covers |
|-----------|-------|---------------|
| TmuxLayoutTests | 32 | Layout parsing, checksum, errors |
| TmuxModelsTests | 14 | TmuxId validation, model equality |
| TmuxSessionNameResolverTests | 35 | Session discovery, name resolution |
| TmuxSplitTreeTests | 63 | Tree ops, zoom, codable, queries |
| TmuxStateReconciliationTests | 22 | reconcileTmuxState() pure logic (including 4 focused-pane tests) |
| TmuxConnectionLifecycleTests | 14 | Notification state machine |
| TmuxDataFlowTests | 10 | SSH data ingress, buffering, DCS chunk boundary |
| TmuxViewerReadyTests | 29 | Viewer ready gating, write routing |
| TmuxSessionManagerTests | 45 | Command formatting, state transitions, handleTmuxStateChanged w/ mock, cleanup, zoom/equalize/resize, removeSurface |
| TmuxWireDiagnosticsTests | 48 | Shadow parser for tmux wire data |
| **TOTAL tmux** | **312** | |

## Test Patterns

### Standard Unit Test

```swift
import XCTest
@testable import Geistty

final class SomethingTests: XCTestCase {
    // Optional setUp with implicitly unwrapped optionals
    // // MARK: - sections to organize
    // Private helper methods in // MARK: - Helpers
}
```

### Mock-Based Test (tmux lifecycle)

```swift
import XCTest
@testable import Geistty

final class TmuxLifecycleTests: XCTestCase {
    var mockSurface: MockTmuxSurface!
    var mockDelegate: MockSSHSessionDelegate!

    override func setUp() {
        super.setUp()
        mockSurface = MockTmuxSurface()
        mockDelegate = MockSSHSessionDelegate()
    }
}
```

### Auth Module Tests (real Keychain)

Auth tests (`KeychainManagerTests`, `SSHKeyManagerTests`) use the real iOS Keychain on the simulator. Each test cleans up its artifacts in `tearDown` to avoid polluting the Keychain.

### Command Capture Pattern (TmuxSessionManagerTests)

Uses a `CommandLog` reference type + `setupWithDirectWrite` closure to capture all commands sent without needing a real SSH connection. Tests verify exact command strings including `\n` termination.

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

# Count passing tests from full log
grep -c "passed on" /tmp/geistty_tests.log
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
| Icarus (iPad Pro) | `00008103-001425D11153001E` | `4E8A6D04-FCF9-5BB5-BF57-22080EC6A31A` |
| Athena (iPhone) | `00008130-001049E23ED0001C` | `55CF3503-DC69-50E1-BC33-17A7DB9ECE9C` |

## Build Artifacts

| Path | Contents |
|------|----------|
| `~/Library/Developer/Xcode/DerivedData/Geistty-*/` | Build outputs |
| `/tmp/geistty_build.log` | Full build log |
| `/tmp/geistty_tests.log` | Full test log |

## Adding New Test Files

New test files must be added to `project.pbxproj`:
- PBXBuildFile entry (build ID pattern: `D100003N`)
- PBXFileReference entry (ref ID pattern: `D200003N`)
- GeisttyTests group children entry
- Test target Sources build phase entry

Next available test IDs: `D2000037` / `D1000037`

## Agent Development Notes

When working as a coding agent:

1. **Always run `./ci.sh build` after code changes** to verify compilation
2. **Run `./ci.sh test` after adding/modifying tests** to verify they pass
3. **Check `/tmp/geistty_build.log` for full error details** if build fails
4. **Use simulator builds** for quick iteration (no signing delays)
5. **Device testing** requires user to verify behavior on Icarus/Athena
6. **New test files** must be added to `project.pbxproj` (see Adding New Test Files above)
