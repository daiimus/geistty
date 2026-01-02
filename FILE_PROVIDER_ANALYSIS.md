# File Provider Extension Analysis

## Executive Summary

After extensive research on Apple's NSFileProviderReplicatedExtension documentation and best practices, I've identified **several critical issues** in the current implementation that would cause the "Authentication Required" error.

**Status Update (Dec 30, 2025):** Most issues have been fixed. See individual issue sections for current status.

---

## Issue #1: `isConnected` Check is Incorrect (HIGH PRIORITY) - ✅ FIXED

### The Problem (Was)

`SFTPClient.isConnected` only checked if the channel object exists.

### The Fix (Applied)

`SFTPClient` now tracks whether `connect()` successfully completed SFTP initialization:

```swift
private var _isConnected = false

var isConnected: Bool {
    _isConnected && channel != nil  // ✅ Only true after channel.open() succeeds
}

func connect(...) async throws {
    try await channel.open()
    self._isConnected = true  // ✅ Set ONLY after successful SFTP init
}
```

---

## Issue #2: `SFTPChannel.channel` vs Real Connectivity (HIGH PRIORITY) - ✅ FIXED

### The Problem (Was)

`SFTPClient.isConnected` only checked if the `SFTPChannel` instance exists, not if it's actually connected.

### The Fix (Applied)

Now properly tracked via `_isConnected` flag set after `channel.open()` succeeds. See Issue #1.

---

## Issue #3: Working Set Enumeration Returns Connections (MEDIUM) - ✅ FIXED (Dec 30, 2025)

### The Problem

From Apple docs:
> "The working set is a list of items that the user may find particularly interesting."
> "Your file provider must maintain its own working set... typically includes recently used items, tagged items, favorites, shared items, recently deleted items."

Original implementation returned `ConnectionsEnumerator()` for the working set.

### The Fix (Applied)

1. Created `WorkingSetEnumerator` that returns cached items from `MetadataCache.shared.getAllItems()`
2. **Bug Fixed (Dec 30)**: `extractConnectionId()` was parsing with wrong format (`"sftp:"` instead of `"conn:"`)
3. Now uses `CachedItem.parseConnectionId()` for consistent ID parsing

```swift
// WorkingSetEnumerator.extractConnectionId - FIXED
private static func extractConnectionId(from itemId: String) -> String? {
    return CachedItem.parseConnectionId(from: itemId)  // Uses "conn:" format
}
```

For a simple implementation, the working set can return empty results initially:

```swift
if containerItemIdentifier == .workingSet {
    return EmptyEnumerator()  // No working set items yet
}
```

Or return an empty array in `enumerateItems`:
```swift
class WorkingSetEnumerator: NSFileProviderEnumerator {
    func enumerateItems(...) {
        observer.didEnumerate([])  // Empty working set
        observer.finishEnumerating(upTo: nil)
    }
}
```

---

## Issue #4: Missing Error Mapping (MEDIUM)

### The Problem

The extension throws `NSFileProviderError(.notAuthenticated)` for credential failures, but also for SSH/SFTP connection errors. The system may interpret any `.notAuthenticated` error as "prompt user for password" even when the real issue is network or server problems.

Current code:
```swift
guard sshKeyData != nil || password != nil else {
    throw NSFileProviderError(.notAuthenticated)  // Correct usage
}

// But later:
// Network errors should be .serverUnreachable
// Invalid credentials should be .notAuthenticated
```

### The Fix

Map errors appropriately:
```swift
} catch let error as NIOSSHError {
    switch error {
    case .connectionFailed:
        throw NSFileProviderError(.serverUnreachable)
    case .authenticationFailed:
        throw NSFileProviderError(.notAuthenticated)
    default:
        throw NSFileProviderError(.cannotSynchronize)
    }
} catch {
    throw NSFileProviderError(.serverUnreachable)
}
```

---

## Issue #5: SSH Auth Happens at Connection Time, Not Enumeration (ARCHITECTURE)

### The Problem

The current flow:
1. User taps connection folder in Files.app
2. `RemoteEnumerator.enumerateItems()` is called
3. `SFTPConnectionManager.getClient()` tries to connect
4. SSH authentication happens NOW
5. If auth fails, enumeration fails with error

But SSH connections can timeout or fail for many reasons (network, server load, key issues). This happens synchronously during enumeration, which causes the "Authentication Required" popup.

### Apple's Best Practice

From the docs:
> "The system calls enumerator(for:request:) to populate that folder."

The enumerator is supposed to be lightweight and return quickly. Heavy network operations should be minimized or made resilient.

### Recommendations

1. **Pre-validate credentials** when user enables Files integration
2. **Cache connection state** and retry gracefully
3. **Return `.serverUnreachable`** for connection failures (not `.notAuthenticated`)
4. **Consider async reconnection** with user notification

---

## Issue #6: `connectForSFTP()` May Not Wait for Auth (HIGH PRIORITY) - ✅ FIXED

### The Problem (Was)

`connectForSFTP()` returned before SSH authentication completed because `bootstrap.connect()` returns when TCP is connected.

### The Fix (Applied)

Added `verifyAuthentication()` method that creates a test channel to verify auth:

```swift
public func connectForSFTP(authMethod: SSHAuthMethod) async throws {
    // ... bootstrap setup ...
    let channel = try await bootstrap.connect(host: connectionHost, port: connectionPort).get()
    
    // CRITICAL: Verify auth completed
    try await verifyAuthentication(on: channel)  // ✅ Opens test channel, closes it
    
    state = .channelOpen
    health = .healthy
}

private func verifyAuthentication(on channel: Channel) async throws {
    let sshHandler = try channel.pipeline.handler(type: NIOSSHHandler.self).wait()
    let channelPromise = channel.eventLoop.makePromise(of: Channel.self)
    sshHandler.createChannel(channelPromise) { ... }  // Will fail if auth not complete
    let testChannel = try await channelPromise.futureResult.get()
    try await testChannel.close().get()  // Success = auth verified
}
```

---

## Issue #7: No Network Entitlement Check

### The Problem

File Provider extensions run in a sandbox. While `com.apple.security.network.client` is typically automatic for app extensions, verify it's present in the extension's entitlements or its parent app's capabilities.

### Current Status

The entitlements file shows:
```xml
<key>com.apple.security.application-groups</key>
<key>keychain-access-groups</key>
```

But no explicit network entitlement. This SHOULD be automatic for File Provider extensions, but worth verifying.

---

## Issue #8: SFTPChannel Uses `await` in Sync Init Closures

### The Problem

In `SFTPChannel.open()`:

```swift
handler.createChannel(channelPromise) { [weak self] childChannel, channelType in
    return childChannel.pipeline.addHandler(
        SFTPChannelHandler(
            onData: { data in
                Task { await self?.handleIncomingData(data) }  // ⚠️ async in sync closure
            },
            ...
        )
    )
}
```

This creates Tasks that capture `self` weakly. If `SFTPChannel` is deallocated before these tasks complete, data could be lost or crashes could occur.

---

## Recommended Testing Approach

1. **Verify SSH auth works standalone**
   ```swift
   // In main app, test NIOSSHConnection.connectForSFTP() directly
   let conn = NIOSSHConnection(host: ..., port: ..., username: ...)
   try await conn.connectForSFTP(authMethod: ...)
   print("SSH connected, parentChannel: \(conn.parentChannel)")
   ```

2. **Verify SFTP channel opens**
   ```swift
   let sftp = SFTPClient(parentChannel: conn.parentChannel!)
   try await sftp.connect(host: ..., username: ...)
   let files = try await sftp.listDirectory("/")
   print("Listed \(files.count) files")
   ```

3. **Check File Provider extension logs**
   Use Console.app filtered to `com.geistty.fileprovider` on the connected device.

---

## Status Summary (Dec 30, 2025)

| Issue | Priority | Status |
|-------|----------|--------|
| #1 - `isConnected` check | HIGH | ✅ Fixed - uses `_isConnected` flag |
| #2 - `SFTPChannel` connectivity | HIGH | ✅ Fixed - see #1 |
| #3 - Working set returns connections | MEDIUM | ✅ Fixed - returns cached files, ID parsing bug fixed |
| #4 - Error mapping | MEDIUM | ✅ Implemented - `toFileProviderError()` |
| #5 - Auth at enumeration time | ARCH | ℹ️ By design - cache fallback mitigates |
| #6 - `connectForSFTP()` auth wait | HIGH | ✅ Fixed - `verifyAuthentication()` |
| #7 - Network entitlements | LOW | ℹ️ Automatic for File Provider extensions |
| #8 - Async in sync closures | LOW | ⚠️ Known - weak self mitigates |

**Current State:** File Provider is functional with browse, view, create, delete, rename operations working. Working set now correctly returns cached files. Change detection via polling is implemented.
---

## Issue #9: "Syncing Paused" Warning - ✅ FIX IMPLEMENTED (Jan 1, 2026)

### Problem

The Files.app shows "Syncing with Geistty Paused" warning with an alert icon, even though browsing and file operations work correctly.

### Root Cause Analysis

After deep investigation of Apple's documentation, the issue is **resolvable errors** (`.notAuthenticated`, `.serverUnreachable`) persisting until explicitly cleared:

> "The system displays an alert... and pauses syncing until the error is resolved."
> "To clear the error, call `signalErrorResolved(_:)`."

The File Provider extension was throwing these errors when not connected to a server, but never clearing them when connections succeeded.

### Fixes Applied (Jan 1, 2026)

| Fix | Location | Description |
|-----|----------|-------------|
| Cache-first in `item(for:)` | `FileProviderExtension.swift` L590-640 | Check `MetadataCache` before requiring server connection |
| Signal errors resolved | `FileProviderExtension.swift` L224 | Call `signalErrorsResolved()` after SFTP connection |
| New `signalErrorsResolved()` | `SFTPConnectionManager` L268-298 | Signals both `.notAuthenticated` and `.serverUnreachable` as resolved |

### Key Insight

Previously, only the **main app** called `signalErrorsResolved()` (in `FileProviderDomainManager`). But the **extension** is what throws the errors, so the **extension** must also signal when they're resolved.

### Status: Needs Device Testing

All unit tests pass (57+). Needs on-device verification to confirm "Syncing Paused" clears.

### Research Findings

After extensive analysis of Apple's documentation and Blink Shell's implementation, here are the key findings:

#### What Causes "Syncing Paused"

The message appears when iOS determines that synchronization cannot proceed. Common causes:

1. **Pending operations with errors** - If `createItem`, `modifyItem`, `deleteItem`, or `fetchContents` return errors, iOS may pause syncing
2. **Extension instability** - Frequent extension restarts (observed in logs: many "Extension init for domain: geistty" entries)
3. **Inconsistent sync anchor state** - The working set enumerator's sync anchor handling may confuse iOS
4. **Not returning items that iOS expects** - If materialized items aren't in the working set

#### Blink's Implementation Pattern

Blink Shell's File Provider (which works without "Syncing Paused"):

1. **WorkingSetEnumerator**:
   - `currentSyncAnchor()` returns an ACTUAL anchor (incremented iteration counter)
   - `enumerateItems()` returns `finishEnumerating(upTo: nil)` immediately (no items)
   - `enumerateChanges()` actually reports creates/updates/deletions from a database

2. **Folder Enumerators**:
   - `currentSyncAnchor()` returns `nil` (stateless)
   - Content comes from actual SFTP enumeration

3. **State Tracking**:
   - Uses SQLite database to track item state
   - Tracks sync anchor iterations
   - Records commits to working set

#### Key Difference from Our Implementation

| Aspect | Blink | Geistty |
|--------|-------|---------|
| WorkingSet anchor | Real iteration counter | `nil` |
| WorkingSet changes | Tracked in SQLite | Not tracked |
| Folder anchors | `nil` | `nil` |
| Change detection | Timer + DB comparison | Timer + SFTP comparison |

#### Hypothesis

The "Syncing Paused" warning may be caused by:

1. **WorkingSet returning `nil` for sync anchor** - iOS may interpret this as "can't track state"
2. **Extension restarts** - Each restart loses state; iOS sees inconsistent behavior
3. **No pending item resolution** - If iOS has pending operations but we never resolve them

### Potential Solutions

#### Option A: Implement Proper Sync Anchor (Blink-style)

Create a persistent sync anchor counter that increments with each change:

```swift
class WorkingSetEnumerator: NSFileProviderEnumerator {
    private static var anchorIteration: UInt64 = 0
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchor = NSFileProviderSyncAnchor("geistty-\(Self.anchorIteration)".data(using: .utf8)!)
        completionHandler(anchor)
    }
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // If anchor matches current, no changes
        // Otherwise, enumerate all changes since that anchor
        observer.finishEnumeratingChanges(upTo: currentAnchor, moreComing: false)
    }
}
```

#### Option B: Use Non-Replicated Extension

If syncing isn't needed (pure remote browsing), consider using the simpler `NSFileProviderExtension` instead of `NSFileProviderReplicatedExtension`. However, this is deprecated and may not be available long-term.

#### Option C: Signal Error Resolution

If there are pending operations with errors, use `signalErrorResolved(_:completionHandler:)` to clear them.

### Current Status

- Multiple approaches tried (returning `nil` for all anchors, matching Blink's pattern)
- Warning persists
- Need to determine exact iOS condition triggering the warning

### Next Steps

1. Capture full extension lifecycle logs to see if operations are failing
2. Check if `enumeratorForPendingItems()` shows stuck operations
3. Consider implementing proper anchor tracking with persistence
4. Test with a minimal working set implementation