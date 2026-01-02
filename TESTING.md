# Testing Guide for Geistty

This document explains how to build, test, and debug Geistty without requiring manual device interaction.

## Quick Start

```bash
cd Geistty

# Build for simulator (no signing required)
./ci.sh build

# Build for device 
./ci.sh device-build

# Install on connected device
./ci.sh install
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
- Tests core logic without UI or network
- Files in `GeisttyTests/`
- Run with: `./ci.sh test`
- **101 tests covering File Provider infrastructure**
- See `GeisttyTests/FILE_PROVIDER_TEST_MATRIX.md` for detailed coverage

### GeisttyUITests (UI Tests)
- Requires a running app instance
- Tests user-facing interactions
- Run with: `./ci.sh ui-test`

## Test Files

| File | Purpose | Tests |
|------|---------|-------|
| `FileProviderTests.swift` | MetadataStore, SyncState, AnchorCache | 40 |
| `FileProviderExtensionTests.swift` | Extension integration, Device-only tests | 46 |
| `FileProviderIntegrationTests.swift` | Mock SFTP→Store→Anchor flow | 7 |
| `MetadataStoreEnumeratorTests.swift` | Enumerator protocol, edge cases | 15 |

## Running Tests

```bash
# Quick test run
cd Geistty && ./ci.sh test

# Direct xcodebuild command
xcodebuild test -project Geistty.xcodeproj -scheme Geistty \
    -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
    -only-testing:GeisttyTests
```

## Test Coverage Summary

| Test Suite | Tests | Description |
|------------|-------|-------------|
| MetadataStoreTests | 10 | CRUD, anchor management, change tracking |
| MetadataStoreEnumeratorTests | 15 | Enumerator protocol, edge cases, deep nesting |
| SyncStateTests | 3 | Anchor serialization/deserialization |
| EnumeratorBehaviorTests | 2 | Incremental change detection |
| MetadataAnchorCacheTests | 2 | Synchronous cache behavior |
| SyncingPausedDiagnosticTests | 14 | "Syncing Paused" root cause coverage (device-only) |
| EnumeratorContractTests | 5 | File Provider protocol contract tests |
| ItemIdentifierTests | 6 | Item ID format parsing |
| CachedMetadataItemTests | 3 | Item properties |
| FileProviderIntegrationTests | 7 | Mock SFTP flow |
| WorkingSetMockTests | 2 | Working set behavior |

### Key Test Categories (Jan 2, 2026)

| Category | Coverage | Key Tests |
|----------|----------|-----------|
| Subfolder Changes | ✅ | `testSubfolderFileChangesAreReported`, `testDeepNestedChangesAreReported` |
| Large Batches | ✅ | `testLargeBatchOfChanges` (100 items) |
| Concurrent Access | ✅ | `testConcurrentEnumerations` (5 parallel) |
| Unicode Filenames | ✅ | `testUnicodeFilenames` (Japanese, Chinese, emoji, etc.) |
| Rapid Changes | ✅ | `testRapidSuccessiveChanges` (50 rapid ops) |
| Symlinks | ✅ | `testSymlinkReporting` |

### "Syncing Paused" Test Coverage

These tests specifically target the known causes of "Syncing Paused":

| Test | Root Cause | Status |
|------|------------|--------|
| `testAnchorIsExactly8Bytes` | Wrong anchor byte count | ✅ Pass |
| `testAnchorNeverStartsAtZero` | Anchor = 0 causes no-change detection | ✅ Pass |
| `testCacheSyncAnchorIsSynchronous` | Async completion handler | ✅ Pass |
| `testIOSCallSequenceSimulation` | iOS call pattern mismatch | ✅ Pass |
| `testEnumerateChangesCompletesWithValidAnchor` | Task {} async flow | ✅ Pass |
| `testSubfolderFileChangesAreReported` | Item filtering bug (Fixed Jan 2, 2026) | ✅ Pass |

**Conclusion**: Core infrastructure is correct. The item filtering bug (subfolder items dropped) was fixed on Jan 2, 2026.
- ~~Extension process not starting (check Console.app for extension logs)~~
- ~~Domain registration timing (try deleting/reinstalling app)~~
- ~~App Group container state (reset via Settings → General → iPhone Storage)~~
- **UPDATE (Jan 1, 2026)**: Root cause identified - **resolvable errors** (`.notAuthenticated`, `.serverUnreachable`) persist until `signalErrorResolved()` is called. Fix implemented: extension now calls `signalErrorsResolved()` after successful SFTP connection. **Needs device testing.**

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

# Filter for specific subsystems
xcrun devicectl device process launch --device DEVICE_ID --console com.geistty.app 2>&1 | \
    grep -E "(FileProvider|MetadataStore|anchor)" --line-buffered
```

## File Provider Debugging

The File Provider extension is particularly tricky to debug. Key areas:

### Sync Anchor Flow
1. iOS calls `currentSyncAnchor(completionHandler:)` - must return synchronously
2. iOS calls `enumerateChanges(for:from:)` with the anchor
3. Extension reports changes since that anchor
4. iOS updates its local cache

### Common Issues

**"Syncing Paused"** - Usually caused by:
- Anchor format mismatch (must be 8-byte UInt64)
- Anchor starting at 0 instead of 1
- Completion handler not called
- Extension crash/timeout

### Key Log Patterns
```bash
# Watch for anchor-related logs
grep -E "(anchor|WS-ENUM|enumerateChanges|currentSyncAnchor)"

# Watch for File Provider extension logs
grep -E "(FP-EXT|FileProvider|GeisttyFileProvider)"
```

### Testing Fresh Install
To simulate a fresh install (resets File Provider state):

1. Delete Geistty from device
2. Reinstall via `./ci.sh install`
3. Open Files.app → Geistty
4. Watch for initial enumeration

## Running Self-Tests

The `MetadataStoreSelfTest` can be triggered from app code:

```swift
// In Debug builds
Task {
    await MetadataStoreSelfTest.run()
}
```

## Known Device IDs

| Device | ID |
|--------|-----|
| Icarus | `00008103-001425D11153001E` |
| Athena | `00008130-001049E23ED0001C` |

## Build Artifacts

| Path | Contents |
|------|----------|
| `~/Library/Developer/Xcode/DerivedData/Geistty-*/` | Build outputs |
| `/tmp/geistty_build.log` | Full build log |
| `test_results/` | Test result bundles |

## Agent Development Notes

When working as a coding agent:

1. **Always run `./ci.sh build` after code changes** to verify compilation
2. **Check `/tmp/geistty_build.log` for full error details** if build fails
3. **Use simulator builds** for quick iteration (no signing delays)
4. **Device testing** still requires user to verify UI behavior in Files.app
5. **The "Syncing Paused" bug** is in the anchor/enumerator dance - focus on `MetadataStoreEnumerator` and `currentSyncAnchor` flow
