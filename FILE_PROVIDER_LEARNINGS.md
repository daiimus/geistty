# File Provider Learnings

**Archived:** January 16, 2026  
**Branch:** `archive/file-provider-jan-2026`  
**Status:** Development paused - complexity outweighed benefits for current stage

This document preserves key learnings from the File Provider implementation attempt for future reference.

---

## Summary

We attempted to build an `NSFileProviderReplicatedExtension` to expose SFTP servers in iOS Files.app. After weeks of development, the implementation worked for browsing but persistently showed "Syncing with Geistty Paused" in Files.app.

**Decision:** Archive and focus on core terminal experience. File Provider can be revisited later.

---

## What Worked

- **SFTP browsing** - Could navigate remote directories in Files.app
- **File operations** - Create, modify, delete files worked on remote server
- **SwiftData persistence** - Metadata caching worked correctly
- **Connection pooling** - `SFTPConnectionManager` deduplication worked

## What Didn't Work

- **"Syncing Paused"** - Persistent banner in Files.app despite code fixes
- **Change propagation** - Local changes didn't reliably appear in Files.app
- **iOS state caching** - iOS caches domain state aggressively; code fixes don't clear it

---

## Key Technical Learnings

### 1. SFTP ≠ Sync Protocol

**The fundamental problem:** SFTP is a file transfer protocol, not a sync protocol.

| SFTP Has | SFTP Lacks |
|----------|------------|
| List, read, write, delete | Change notifications |
| File attributes (size, mtime) | Revision history |
| Directory traversal | Server-side anchors |
| | Push events |

File Provider expects sync semantics (anchors, change streams). We faked it with polling and local change tracking, but the impedance mismatch created complexity.

### 2. Apple's Anchor Contract

```swift
// iOS asks for current anchor
func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void)

// iOS asks for changes since anchor
func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor)
```

**Critical rules:**
1. Anchors must be **monotonically increasing**
2. `enumerateChanges` must return ALL changes since the given anchor
3. If anchor is too old, return `NSFileProviderError.syncAnchorExpired`
4. Never return `nil` for `currentSyncAnchor()` - iOS interprets this as error

### 3. Anchor Format

We went through multiple anchor formats:

| Format | Issues |
|--------|--------|
| `VERSION-ITERATION` string | Parsing complexity, version mismatch handling |
| 8-byte `UInt64` | Simple but no version migration |
| `V{version}-{iteration}` | Best - includes schema version for future migration |

**Final format:** `"V1-42"` = version 1, iteration 42

### 4. Single Source of Truth

**Failed approach:** Three anchor sources
1. SwiftData `SyncState` (ground truth)
2. `MetadataAnchorCache` (in-memory cache for sync access)
3. `sync_anchor.dat` (file backup)

**Problem:** These could desync, causing iOS to see inconsistent state.

**Correct approach:** SwiftData only. Use `Task{}` for async access in callbacks (Apple docs allow this).

### 5. Commit Every Write

**Blink's pattern:**
```swift
return self.workingSet.commitItemInSet(itemPath: itemPath) {
    // ... do SFTP operation ...
    return createdItem
}
```

Every `createItem`/`modifyItem`/`deleteItem` must immediately update the metadata store AND call `signalEnumerator(.workingSet)`.

### 6. iOS State Caching

iOS aggressively caches File Provider domain state. Code fixes don't clear this cache.

**Solution:** Domain reset function that:
1. Removes the domain
2. Clears all metadata
3. Waits for iOS to process
4. Re-adds domain fresh

```swift
func resetDomain() async throws {
    try await NSFileProviderManager.remove(domain)
    try await MetadataStore.shared.resetForDomainClear()
    try await Task.sleep(for: .milliseconds(500))
    try await NSFileProviderManager.add(domain)
}
```

### 7. Resolvable Errors

These errors cause "Syncing Paused" until explicitly cleared:
- `.notAuthenticated`
- `.serverUnreachable`
- `.syncAnchorExpired`
- `.cannotSynchronize`
- `.insufficientQuota`

**Must call:**
```swift
manager.signalErrorResolved(error) { _ in }
```

---

## Architecture Patterns

### What Blink Does (Reference Implementation)

```
WorkingSetEnumerator ──► WorkingSetDatabase (SQLite) ──► Anchor tracking
                                    ▲
                                    │
FileProviderReplicatedEnumerator ───┘ (folder browsing populates DB)
                                    │
                                    ▼
                              SFTP Server
```

- **One database** for all metadata
- **One anchor counter** (monotonic)
- **Polling timer** for server-side change detection
- **Strict anchor validation** (version mismatch → expired)

### What We Built

```
MetadataStoreEnumerator ──► MetadataStore (SwiftData) ──► SyncState
                                    ▲
                                    │
RemoteEnumerator ───────────────────┘
ConnectionsEnumerator ──────────────┘
                                    │
                                    ▼
                              SFTP Server
```

Similar structure, but more complexity around anchor caching.

---

## Failed Approaches (Do Not Repeat)

| Approach | Why It Failed |
|----------|---------------|
| Adding debug logging as first step | Created bloat, didn't identify root cause |
| `signalErrorResolved()` without domain reset | iOS state already corrupted |
| Multiple anchor caches | Desync problems |
| File-based anchor backup | Third source of truth |
| Testing on device before understanding problem | Wasted cycles |
| Parent-in-modified-set filter | Dropped subfolder items |

---

## Code That Was Worth Keeping

These files are useful beyond File Provider:

| File | Purpose | Keep? |
|------|---------|-------|
| `SFTPClient.swift` | High-level async SFTP API | ✅ |
| `SFTPChannel.swift` | Low-level SFTP protocol | ✅ |
| `SFTPClientProtocol.swift` | Protocol for mocking | ✅ |

These files were specific to File Provider and archived:

| File | Purpose |
|------|---------|
| `FileProviderExtension.swift` | Main extension |
| `MetadataStore.swift` | SwiftData actor |
| `MetadataStoreEnumerator.swift` | Working set enumerator |
| `SyncState.swift` | Anchor @Model |
| `CachedFileMetadata.swift` | Item @Model |
| `ActiveFolderRecord.swift` | Polling @Model |
| `FileProviderDomainManager.swift` | Domain management |

---

## If We Revisit This

1. **Start simpler** - Read-only browsing first, no sync
2. **Use SQLite directly** - Match Blink's pattern exactly
3. **One source of truth** - No caching layers
4. **Test with domain reset** - Always reset before testing fixes
5. **Consider non-replicated extension** - Simpler API if sync not needed

---

## References

- [Apple: Synchronizing files using file provider extensions](https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions)
- [Apple: NSFileProviderReplicatedExtension](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension)
- [Blink Shell File Provider](https://github.com/blinksh/blink/tree/main/BlinkFileProvider)
- [WWDC 2021: Sync files to the cloud with FileProvider on macOS](https://developer.apple.com/videos/play/wwdc2021/10182/)

---

## Archive Location

Full implementation preserved at:
```
git checkout archive/file-provider-jan-2026
```
