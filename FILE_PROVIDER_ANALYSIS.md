# File Provider Extension Analysis

## Executive Summary

After extensive research on Apple's NSFileProviderReplicatedExtension documentation and best practices, I've identified **several critical issues** in the current implementation that would cause the "Authentication Required" error.

---

## Issue #1: `isConnected` Check is Incorrect (HIGH PRIORITY)

### The Problem

In `SFTPConnectionManager.getClient()`:

```swift
if let client = sftpClients[connectionId], await client.isConnected {
    return client
}
```

But `SFTPClient.isConnected` only checks if the channel object exists:

```swift
var isConnected: Bool {
    channel != nil  // ❌ This doesn't verify the channel is ACTUALLY working
}
```

After `connectForSFTP()`, the SSH channel exists but:
1. The SFTP subsystem channel hasn't been opened yet
2. The channel might be in a broken state
3. There's no actual connectivity test

### The Fix

`SFTPClient` needs to track whether `connect()` successfully completed SFTP initialization:

```swift
private var _isConnected = false

var isConnected: Bool {
    channel != nil && _isConnected
}

func connect(host: String, username: String) async throws {
    // ... existing code ...
    _isConnected = true  // Set ONLY after successful SFTP init
}
```

---

## Issue #2: `SFTPChannel.channel` vs Real Connectivity (HIGH PRIORITY)

### The Problem

`SFTPClient.isConnected` checks if `channel` (the underlying `SFTPChannel`) exists:

```swift
var isConnected: Bool {
    channel != nil
}
```

But `SFTPChannel` is created in `init(parentChannel:)` without opening anything:

```swift
init(parentChannel: Channel) {
    self.parentChannel = parentChannel  // Just stores reference
    // channel property remains nil until open() is called!
}
```

So after `SFTPClient(parentChannel: parentChannel)`, we have:
- `SFTPClient.channel` = SFTPChannel instance (exists)
- `SFTPChannel.channel` = nil (not opened yet)
- `SFTPChannel.isConnected` = false

When `SFTPClient.connect()` is called, it should:
1. Call `channel.open()` to create SFTP subsystem
2. Set `SFTPChannel.isConnected = true`

But `SFTPClient.isConnected` only checks if the `SFTPChannel` instance exists, not if it's actually connected.

### The Fix

```swift
// In SFTPClient
var isConnected: Bool {
    get async {
        guard let channel = channel else { return false }
        return channel.isConnected  // Delegate to SFTPChannel's state
    }
}
```

---

## Issue #3: Working Set Enumeration Returns Connections (MEDIUM)

### The Problem

From Apple docs:
> "The working set is a list of items that the user may find particularly interesting."
> "Your file provider must maintain its own working set... typically includes recently used items, tagged items, favorites, shared items, recently deleted items."

Current implementation:
```swift
if containerItemIdentifier == .workingSet {
    return ConnectionsEnumerator()  // ❌ Returns same as root
}
```

The working set should contain **actual remote files** the user has accessed, not connection folders.

### The Fix

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

## Issue #6: `connectForSFTP()` May Not Wait for Auth (HIGH PRIORITY)

### The Problem

Looking at `connectForSFTP()`:

```swift
public func connectForSFTP(authMethod: SSHAuthMethod) async throws {
    // ... bootstrap setup ...
    
    let channel = try await bootstrap.connect(host: connectionHost, port: connectionPort).get()
    self.channel = channel
    
    // For SFTP, we DON'T open a shell channel - the SFTPChannel will create its own
    state = .channelOpen
    health = .healthy
}
```

The SSH handshake includes authentication, but we're not waiting for auth completion. The `bootstrap.connect()` returns when TCP is connected, but SSH authentication happens asynchronously via the `NIOSSHHandler`.

In the original `connect()` method, we wait for `openShellChannel()` which implicitly waits for auth because you can't open a channel without being authenticated. But `connectForSFTP()` skips this.

### The Fix

Need to wait for SSH authentication to complete before returning from `connectForSFTP()`. Either:

1. Open a dummy channel and close it (confirms auth works)
2. Use NIOSSH's auth completion callback
3. Try to get the NIOSSHHandler and wait for auth state

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

## Root Cause Hypothesis

The most likely root cause is **Issue #6**: `connectForSFTP()` returns before SSH authentication actually completes. The TCP connection is established, but:

1. SSH handshake hasn't finished
2. `parentChannel` is returned immediately
3. `SFTPChannel.open()` tries to use `NIOSSHHandler.createChannel()`
4. This fails because auth isn't complete yet
5. Error is caught and mapped to `.notAuthenticated`

**Proof**: The original `connect()` method works because `openShellChannel()` forces waiting for auth. `connectForSFTP()` was added without this synchronization.

---

## Immediate Fix Priority

1. **HIGH**: Fix `connectForSFTP()` to wait for SSH auth completion
2. **HIGH**: Fix `SFTPClient.isConnected` to actually verify SFTP subsystem is open
3. **MEDIUM**: Map errors correctly (`.serverUnreachable` vs `.notAuthenticated`)
4. **LOW**: Fix working set enumeration
