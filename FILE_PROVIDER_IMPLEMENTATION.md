# File Provider Implementation Guide

## Overview

This document captures the research, best practices, and implementation details for Geistty's `NSFileProviderReplicatedExtension` implementation. The goal is a **best-of-breed** Files.app integration.

---

## Current Status (Jan 3, 2026)

| Question | Answer |
|----------|--------|
| **Active enumerator** | `MetadataStoreEnumerator` (for working set) |
| **Symptom** | "Syncing with Geistty Paused" in Files.app |
| **Browsing works?** | Yes - can navigate folders, see files |
| **Changes reflect?** | 🔄 Testing after dual-cache fix |
| **Alert gone?** | ✅ Yes - the error alert is gone |
| **Unit Tests** | All 97 passing (+ 27 skipped device-only tests) |
| **Protocol Coverage** | All required properties ✅ |
| **Domain Reset** | ✅ Available via `FileProviderDomainManager.resetDomain()` |
| **Code Audit** | ✅ Phase 1, 2 & 3 cleanup complete (~1100 lines removed) |

### 🎯 Root Cause #2: Dual Cache Systems (Jan 3, 2026)

**Discovery:** TWO PARALLEL CACHE SYSTEMS existed, causing stale data:

1. **MetadataCache + CachedItem** (~500 lines) - Used by `RemoteEnumerator` for directory browsing
2. **MetadataStore + CachedFileMetadata** - Used by `MetadataStoreEnumerator` for working set

**Problem:** When items were created/modified/deleted, they were committed to `MetadataStore` but directory browsing used `MetadataCache` which held stale data. This caused:
- Files created not appearing in directory listings
- Deleted folders still showing
- General "stale data" behavior

**Fix Applied (Jan 3, 2026):**
- Updated `item(for:)` to use `MetadataStore.shared.item(id:)` instead of `MetadataCache`
- Updated `enumerateItems` fallback to use `MetadataStore.shared.items(inFolder:)` instead of `MetadataCache`
- Rewrote `refreshFromServer()` to only update `MetadataStore`, returning `CachedMetadataItem` objects
- Added full write capabilities to `CachedMetadataItem.capabilities`
- **DELETED** `MetadataCache.swift` (359 lines)
- **DELETED** `CachedItem.swift` (137 lines)
- **DELETED** `CachedRemoteItem` class

**Total code removed in this fix:** ~500 lines of duplicate dead code

### Previous Fix: MetadataStore Commits (Jan 2, 2026)

**Hypothesis:** Items created via `createItem()` were NOT committed to MetadataStore.

**Fix Applied:**
- Added `MetadataStore.shared.upsert()` call in `createItem()` after successful remote creation
- Added `MetadataStore.shared.upsert()` call in `modifyItem()` after successful modification
- Added `MetadataStore.shared.markDeleted()` call in `deleteItem()` after successful deletion
- Added `signalEnumerator(for: .workingSet)` after all operations (Blink pattern)

**Device Test Result (Jan 2, 2026):** Partial success
- Error alert is gone (improvement)
- "Syncing Paused" banner still shows
- Directory still doesn't reflect changes → led to discovery of dual cache issue

**Root Cause Analysis:**
- iOS persists File Provider domain state even after code fixes
- Legacy anchor formats from previous implementations may confuse iOS
- Two separate anchor caches existed (legacy `SyncAnchorCache` + new `MetadataAnchorCache`)
- Domain corruption from crashes or previous bad implementation

**Solution:** Domain reset clears all state and re-registers fresh:

```swift
// In FileProviderDomainManager
func resetDomain() async throws {
    // 1. Remove the domain if it exists
    // 2. Clear MetadataStore (all items + anchor reset to 1)
    // 3. Wait 0.5s for iOS to process
    // 4. Re-add the domain fresh
}
```

**Usage:** Call from Settings or a debug menu when "Syncing Paused" persists.

### Bug Fix: Missing itemVersion (Jan 2, 2026) ✅

**Root Cause Found and Fixed:**

The `CachedMetadataItem` class (used in `enumerateChanges` to report items to iOS) was missing the **required** `itemVersion` property. This property is mandatory for `NSFileProviderReplicatedExtension` - without it, iOS may reject items or show "Syncing Paused".

**Fix:** Added `itemVersion` property to `CachedMetadataItem`:

```swift
var itemVersion: NSFileProviderItemVersion {
    let modTime = metadata.modificationDate?.timeIntervalSince1970 ?? 0
    let contentVer = "\(metadata.size):\(modTime)".data(using: .utf8)!
    let metaVer = "\(modTime)".data(using: .utf8)!
    return NSFileProviderItemVersion(contentVersion: contentVer, metadataVersion: metaVer)
}
```

**Test:** `CachedMetadataItemTests.testItemVersionIsPresent()` - verifies the property exists and has valid format.

### Bug Fix: Item Filtering (Jan 2, 2026) ✅

**Root Cause Found and Fixed:**

The `MetadataStoreEnumerator.enumerateChanges()` method had an overly aggressive filter that only reported items if:
1. Parent was "root"
2. Parent was a connection root (conn:xxx)
3. **Parent was also in the current modified set**

The third condition was the bug: files in subfolders would be filtered out when their parent folder wasn't modified in the same batch.

**Fix:** Removed the filter entirely. Now all modified items are reported to iOS. iOS handles parent resolution gracefully - if a parent doesn't exist yet, the item just won't display until the parent is enumerated.

**Test:** `MetadataStoreEnumeratorTests.testSubfolderFileChangesAreReported()` - verifies files in subfolders are reported even when parent wasn't modified.

### 🔍 Research Findings: Comparing with Blink Shell (Jan 2, 2026)

Analyzed [Blink Shell](https://github.com/blinksh/blink)'s File Provider implementation for reference.

#### Key Finding: Items Must Be Committed to MetadataStore

**Blink's pattern:**
```swift
// Every createItem/modifyItem commits to WorkingSet database
return self.workingSet.commitItemInSet(itemPath: itemPath) {
    // ... create/modify file on remote ...
    return createdItem
}
```

**Geistty's current pattern:**
```swift
// createItem does NOT commit to MetadataStore!
func createItem(...) {
    // 1. Create on remote server ✅
    // 2. Return item to iOS ✅
    // 3. Signal parent enumerator ✅
    // 4. Commit to MetadataStore ❌ MISSING!
}
```

#### Impact on "Syncing Paused"

1. iOS creates an item through our extension
2. We create it on the remote server and return success
3. iOS may call `enumerateChanges` for the working set
4. `MetadataStoreEnumerator` queries MetadataStore for changes
5. **The newly created item is NOT in MetadataStore**
6. iOS gets confused - it just created an item but we don't report it in changes

#### Fix Required

Add MetadataStore commits in:
- `createItem()` - after successful remote creation
- `modifyItem()` - after successful remote modification
- `deleteItem()` - after successful remote deletion (to track deletion)

```swift
// In createItem, after remote success:
let metadata = CachedFileMetadata(
    itemIdentifier: newItem.itemIdentifier.rawValue,
    parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
    filename: itemTemplate.filename,
    isDirectory: itemTemplate.contentType == .folder,
    size: Int64(attrs.size),
    modificationDate: attrs.modificationTime
)
_ = try await MetadataStore.shared.upsert(metadata)
```

#### Other Blink Patterns

| Pattern | Blink | Geistty |
|---------|-------|---------|
| WorkingSet database | SQLite | SwiftData ✅ |
| Empty enumerateItems | ✅ Returns empty + nil | ✅ Same |
| Commit on create | ✅ Always | ❌ Missing |
| Signal after ops | ✅ Parent + workingSet | ⚠️ Parent only |
| Active enumerator tracking | ✅ PollCoordinator | ⚠️ ActiveFolder in store |

### Failed Approaches (Do Not Repeat)

| Approach | Why It Failed |
|----------|---------------|
| Adding debug logging | Created bloat, didn't identify root cause |
| `signalErrorResolved()` after SFTP connect | No effect on "Syncing Paused" |
| `clearPendingErrors()` on app launch | No effect on "Syncing Paused" |
| Async `Task{}` in callbacks | Apple says async is allowed, didn't fix issue |
| Parent-in-modified-set filter | **REMOVED** - caused subfolder items to be dropped |
| Missing `itemVersion` on items | **FIXED** - Required property for replicated extension |

### Next Steps

1. ✅ **Add `MetadataStoreEnumeratorTests.swift` to the Xcode test target** - Done
2. ✅ **Run the new `testSubfolderFileChangesAreReported` test** - Confirmed bug, now passes after fix
3. ✅ **Fix the filtering logic** - Removed overly aggressive filter
4. ✅ **Add `itemVersion` to `CachedMetadataItem`** - Required property was missing
5. ✅ **Audit all NSFileProviderItem classes for protocol compliance** - Jan 2, 2026
6. ✅ **Add domain reset function** - `FileProviderDomainManager.resetDomain()`
7. **Device testing** - Try domain reset if "Syncing Paused" persists

---

## Anchor Strategy Comparison (Jan 2, 2026)

Analyzed how other iOS File Provider implementations handle sync anchors.

### Our Approach (Geistty)

| Aspect | Implementation |
|--------|----------------|
| Format | `UInt64` monotonic counter |
| Persistence | `sync_anchor.dat` in app group container |
| Initial value | `1` (never use `0` - that indicates "initial sync") |
| Validation | **Permissive** - accepts any older anchor |
| On mismatch | Returns all items since anchor `0` |

```swift
// MetadataAnchorCache
func currentAnchor() -> UInt64 { cachedAnchor }  // Returns 1 or last known

// MetadataStoreEnumerator
func enumerateChanges(from anchor: UInt64) {
    let items = store.itemsModifiedSince(anchor: anchor)
    observer.finishEnumeratingChanges(upTo: currentAnchor)
}
```

### Blink's Approach (blink-shell/blink)

| Aspect | Implementation |
|--------|----------------|
| Format | `"VERSION-ITERATION"` string (e.g., `"1-5"`) |
| Validation | **Strict** - requires `iteration + 1` |
| On mismatch | Returns `NSFileProviderError(.syncAnchorExpired)` |

```swift
// Blink's SyncAnchor
struct SyncAnchor {
    let version: Int
    let iteration: Int
    
    func description() -> String { "\(version)-\(iteration)" }
}

// Blink's validation
func enumerateChanges(from anchor: NSFileProviderSyncAnchor) {
    let providedAnchor = SyncAnchor(anchor.rawValue)
    if providedAnchor.iteration + 1 != currentAnchor.iteration {
        observer.finishEnumerating(error: NSFileProviderError(.syncAnchorExpired))
        return
    }
    // Continue with changes...
}
```

### Cryptomator's Approach (cryptomator/ios)

| Aspect | Implementation |
|--------|----------------|
| Format | JSON-encoded struct with `invalidated: Bool` and `date: Date` |
| Validation | Checks `invalidated` flag and date comparison |
| Reset strategy | Set `invalidated = true` to force full re-enumeration |

```swift
// Cryptomator's SyncAnchor
struct SyncAnchor: Codable {
    var invalidated: Bool
    var date: Date
}

// Cryptomator's validation  
func enumerateChanges(from anchor: Data) {
    let syncAnchor = try JSONDecoder().decode(SyncAnchor.self, from: anchor)
    if syncAnchor.invalidated {
        // Return all items (full re-enumeration)
    } else {
        // Return changes since syncAnchor.date
    }
}
```

### Implications for "Syncing Paused"

| Scenario | Blink | Cryptomator | **Geistty** |
|----------|-------|-------------|-------------|
| iOS sends old anchor | Error, re-enumerate | Date comparison | Returns all items |
| App version update | `version` bump detects | `invalidated` flag | ⚠️ **Silent mismatch** |
| iOS has cached state | Explicit error handling | Explicit invalidation | May return wrong data |

**Key Risk Identified**: If iOS cached anchors from a previous Geistty implementation using a different format (e.g., the legacy `SyncAnchorCache` used `VERSION-ITERATION` strings), our `UInt64` parser would return `0`, which means "return everything since the beginning" - but iOS might interpret this differently.

**Solution**: The `resetDomain()` function clears all iOS cached state and starts fresh.

---

## NSFileProviderItem Protocol Audit (Jan 2, 2026)

### Apple Protocol Requirements

From [NSFileProviderItemProtocol](https://developer.apple.com/documentation/fileprovider/nsfileprovideritemprotocol):

#### Required Properties (MUST implement)

| Property | Type | Description |
|----------|------|-------------|
| `itemIdentifier` | `NSFileProviderItemIdentifier` | Unique persistent identifier |
| `parentItemIdentifier` | `NSFileProviderItemIdentifier` | Parent folder's identifier |
| `filename` | `String` | Display name |

#### Required for iOS 14+ (effectively required)

| Property | Type | Description |
|----------|------|-------------|
| `contentType` | `UTType` | Uniform Type Identifier (replaces deprecated `typeIdentifier`) |
| `capabilities` | `NSFileProviderItemCapabilities` | What user can do with item |

#### Required for Replicated Extension

| Property | Type | Description |
|----------|------|-------------|
| `itemVersion` | `NSFileProviderItemVersion` | **CRITICAL**: Tracks content/metadata changes |

#### Important Optional Properties

| Property | Type | When to implement |
|----------|------|-------------------|
| `documentSize` | `NSNumber?` | Files (size in bytes) |
| `contentModificationDate` | `Date?` | When content last changed |
| `creationDate` | `Date?` | When item was created |
| `childItemCount` | `NSNumber?` | Directories (number of children) |
| `symlinkTargetPath` | `String?` | Symlinks only |
| `isTrashed` | `Bool` | If item is in trash |

#### Transfer Status Properties (Optional but useful)

| Property | Type | Description |
|----------|------|-------------|
| `isUploading` | `Bool` | Currently uploading |
| `isUploaded` | `Bool` | Successfully uploaded |
| `uploadingError` | `Error?` | Upload error |
| `isDownloading` | `Bool` | Currently downloading |
| `isDownloaded` | `Bool` | Successfully downloaded |
| `downloadingError` | `Error?` | Download error |

### Our Item Classes Audit

We have **5 classes** implementing `NSFileProviderItem`:

| Class | Location | Purpose |
|-------|----------|---------|
| `CachedMetadataItem` | `MetadataStoreEnumerator.swift` | Working set enumerator items |
| `RootItem` | `FileProviderExtension.swift` | Root container |
| `ConnectionFolderItem` | `FileProviderExtension.swift` | Connection folders in root |
| `RemoteItem` | `FileProviderExtension.swift` | Live SFTP items |
| `CachedRemoteItem` | `FileProviderExtension.swift` | Cached SFTP items |

### Property Coverage Matrix (Updated Jan 2, 2026)

| Property | `CachedMetadataItem` | `RootItem` | `ConnectionFolderItem` | `RemoteItem` | `CachedRemoteItem` |
|----------|:--------------------:|:----------:|:----------------------:|:------------:|:------------------:|
| **Required** |
| `itemIdentifier` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `parentItemIdentifier` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `filename` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `contentType` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `capabilities` | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Replicated Extension** |
| `itemVersion` | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Optional (Important)** |
| `documentSize` | ✅ | ❌ N/A | ❌ N/A | ✅ | ✅ |
| `contentModificationDate` | ✅ | ❌ | ❌ | ✅ | ✅ |
| `creationDate` | ✅ | ❌ | ❌ | ✅ | ✅ |
| `childItemCount` | ❌ Deferred | ❌ N/A | ❌ N/A | ❌ Deferred | ❌ Deferred |
| `symlinkTargetPath` | ❌ Deferred | ❌ N/A | ❌ N/A | ❌ Deferred | ❌ Deferred |
| **Transfer Status** |
| `isUploading` | ✅ `false` | ✅ `false` | ✅ `false` | ✅ `false` | ✅ `false` |
| `isUploaded` | ✅ `true` | ✅ `true` | ✅ `true` | ✅ `true` | ✅ `true` |
| `isDownloading` | ✅ `false` | ✅ `false` | ✅ `false` | ✅ `false` | ✅ `false` |
| `isDownloaded` | ✅ dirs only | ✅ `true` | ✅ `true` | ✅ dirs only | ✅ dirs only |

### Implemented Transfer Status Rationale

Since Geistty is currently **read-only** (SFTP browsing, no uploads):

| Property | Value | Why |
|----------|-------|-----|
| `isDownloaded` | `true` for folders, `false` for files | Folders can be browsed immediately. Files are streamed on demand via `startProvidingItem`. |
| `isUploaded` | `true` | All items exist on the remote server (we're showing server state) |
| `isDownloading` | `false` | Downloads happen synchronously through `startProvidingItem`, not tracked in item state |
| `isUploading` | `false` | No uploads supported yet |

### Remaining Optional Property Gaps (Deferred)

1. **`symlinkTargetPath`** - Not implemented for symlinks
   - **When needed**: Only for items with `contentType` of `public.symlink`
   - **Requirement**: SFTP `readlink` command to resolve target path
   - **Our status**: `CachedFileMetadata` has `isSymlink` but we don't expose symlinks yet
   - **Impact**: Symlinks appear as regular files/folders
   - **Decision**: Deferred until symlink support is prioritized

2. **`childItemCount`** - Not implemented for directories
   - **What it does**: Shows folder item count in Files.app (e.g., "5 items")
   - **Reference**: Cryptomator returns `nil` (doesn't implement)
   - **Impact**: Minor UX - Files.app shows nothing until enumerated
   - **Decision**: Deferred - not critical, can add when we cache child counts

### Test Coverage for Protocol Properties

| Test | Status | Verifies |
|------|--------|----------|
| `testFileItemProperties()` | ✅ | Basic file properties |
| `testDirectoryItemProperties()` | ✅ | Directory properties |
| `testParentIdentifierMapping()` | ✅ | Parent ID → .rootContainer |
| `testItemVersionIsPresent()` | ✅ | itemVersion exists and has valid format |
| `testAllRequiredPropertiesPresent()` | ✅ | All required props implemented |
| `testItemVersionChangesOnUpdate()` | ✅ | itemVersion changes when item updates |
| `testDocumentSizeForFiles()` | ✅ | documentSize is implemented |
| `testDatePropertiesPresent()` | ✅ | contentModificationDate, creationDate |
| `testContentTypeForDirectories()` | ✅ | contentType is .folder for dirs |
| `testCapabilitiesDifferByType()` | ✅ | capabilities differ for files vs dirs |

**Total: 10 protocol property tests for `CachedMetadataItem`**

### Cross-Class Consistency

All 5 `NSFileProviderItem` classes follow the same pattern for `itemVersion`:

```swift
var itemVersion: NSFileProviderItemVersion {
    let modTime = <modification_date>?.timeIntervalSince1970 ?? 0
    let contentVer = "\(<size>):\(modTime)".data(using: .utf8)!
    let metaVer = "\(modTime)".data(using: .utf8)!
    return NSFileProviderItemVersion(contentVersion: contentVer, metadataVersion: metaVer)
}
```

| Class | itemVersion Source |
|-------|-------------------|
| `CachedMetadataItem` | `metadata.size`, `metadata.modificationDate` |
| `RemoteItem` | `attributes.size`, `attributes.modificationDate` |
| `CachedRemoteItem` | `cachedItem.size`, `cachedItem.modificationDate` |
| `RootItem` | Connection count (changes when connections added/removed) |
| `ConnectionFolderItem` | Static (connection ID) |

---

## Apple Documentation Analysis (Jan 2, 2026)

### Key Requirements from Apple Docs

**From [Synchronizing the File Provider Extension](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension):**

1. **Working Set MUST include all materialized items:**
   > "To ensure that the system applies remote updates to local copies, the working set must also include all materialized items managed by the system when using a replicated file provider."
   
2. **If not tracking materialized items, include ALL items:**
   > "If your file provider doesn't explicitly track materialized items, the working set must include all items (documents and directories) on your remote storage."

3. **System ALWAYS tracks working set changes:**
   > "The system always tracks changes to the working set. If it doesn't have an active enumerator for the working set, it creates a new one."

4. **When signaling changes, signal BOTH the item AND working set:**
   > "Call signalEnumerator(for:completionHandler:) a second time. Pass the workingSet constant... This tells the system to update the working set."

**From [NSFileProviderSyncAnchor](https://developer.apple.com/documentation/fileprovider/nsfileprovidersyncanchor):**

5. **Anchor format is flexible:**
   > "For example, a simple sync anchor could use the time and date of the last update successfully downloaded from the server."

6. **System only retains last anchor:**
   > "The system only retains the last anchor passed to it. After the system calls enumerateChanges(for:from:) with a sync anchor, it's safe to deallocate any older sync anchors."

**From [Tracking Your File Provider's Changes](https://developer.apple.com/documentation/fileprovider/tracking-your-file-provider-s-changes):**

7. **enumerateChanges IS asynchronous:**
   > "This method is asynchronous. When it's called, the enumerator gathers information about the items (perhaps from a remote server) in the background, and returns the results to the specified observer."

### Gap Analysis: Our Implementation vs Apple Requirements

| Apple Requirement | Our Implementation | Compliant? |
|-------------------|-------------------|------------|
| Working set includes all materialized items | We track via `materializedItemsDidChange()` | ✅ Implemented |
| OR include ALL items if not tracking | We only include visited folders | ⚠️ **PARTIAL** |
| Signal BOTH container AND `.workingSet` | `pollActiveFolders()` signals both | ✅ Implemented |
| `currentSyncAnchor()` returns valid anchor | Via `MetadataAnchorCache` | ✅ Implemented |
| `enumerateChanges()` can be async | Using `Task{}` | ✅ Allowed |

### 🔴 Key Finding: Working Set Content Issue

Apple says:
> "If your file provider doesn't explicitly track materialized items, **the working set must include all items** (documents and directories) on your remote storage."

We ARE tracking materialized items via `materializedItemsDidChange()`, so we should be compliant. BUT:
- Are we actually adding those items to our working set enumerator's response?
- When `enumerateChanges()` is called on the working set, do we return the materialized items?

**This needs verification via unit test.**

### � FIXED: Item Filtering Bug (Jan 2, 2026)

In `MetadataStoreEnumerator.swift`, there WAS aggressive filtering that caused items in subfolders to be dropped:

```swift
// OLD CODE (REMOVED):
let validItems = modified.filter { item in
    let parent = item.parentIdentifier
    
    // Root container is always valid
    if parent == "root" { return true }
    
    // Connection roots (conn:xxx without :path:) are valid
    if parent.hasPrefix("conn:") && !parent.contains(":path:") { return true }
    
    // Parent is also in the modified set
    if modifiedIds.contains(parent) { return true }
    
    return false  // ❌ FILTERED OUT - This was the bug!
}
```

**Problem**: If `/foo/bar.txt` is modified but `/foo` is NOT modified, `bar.txt` got filtered out and never reported to iOS!

**Fix**: Removed the filter entirely. Now all modified items are reported:

```swift
// NEW CODE:
// Note: We report ALL modified items. iOS will handle parent resolution.
if !modified.isEmpty {
    let items = modified.map { CachedMetadataItem(metadata: $0) }
    observer.didUpdate(items)
}
```

**Test**: `testSubfolderFileChangesAreReported()` verifies this fix.

---

## Perspective Shift: Files.app is the Driver (Jan 1, 2026)

**Critical realization**: The File Provider extension is NOT a Geistty feature - it's an iOS/Files.app integration point where **Files.app is in complete control**.

### What Files.app Does

Files.app:
1. **Owns the lifecycle** - Creates/destroys our extension process at will
2. **Drives all interactions** - Calls our methods when IT needs data
3. **Maintains state** - Tracks sync anchors, materialized items, domain state
4. **Decides what to display** - "Syncing Paused" is Files.app's assessment of our health

### What "Syncing Paused" Really Means

From Files.app's perspective, "Syncing Paused" means:
> "I asked this provider for sync state, and what it told me doesn't match what I expect. I'm pausing sync until it makes sense again."

This is NOT a bug to fix - it's Files.app telling us we're not speaking its protocol correctly.

### The Contract We Must Honor

Files.app expects:

| Files.app Action | Our Required Response |
|-----------------|----------------------|
| Calls `currentSyncAnchor()` | Return a stable anchor representing our current state |
| Calls `enumerateChanges(from: anchor)` | Return changes since that anchor, OR same anchor if none |
| Calls `enumerateItems()` | Return items in the requested container |
| Sends `signalEnumerator()` | We triggered this; Files.app will call `enumerateChanges()` |

### What Files.app Tracks

Files.app maintains its own state:
- **Last known anchor** - From our `currentSyncAnchor()` or `finishEnumeratingChanges(upTo:)`
- **Materialized items** - Files it has downloaded to device
- **Domain health** - Whether we're responding correctly

### The Real Questions

Instead of "why is Syncing Paused showing?", we should ask:

1. **What anchor did Files.app last see from us?**
2. **What does Files.app expect when it calls `enumerateChanges()`?**
3. **Are we returning what Files.app needs to update its UI?**

### Hypothesis: State Mismatch

"Syncing Paused" likely means:
- Files.app has anchor X stored
- Files.app calls `enumerateChanges(from: X)`
- We return anchor Y with no changes
- Files.app thinks: "They jumped from X to Y but reported no changes? Something's wrong."

OR:
- Files.app calls `currentSyncAnchor()`
- We return `nil` or inconsistent anchor
- Files.app thinks: "They don't know their own state? Pausing."

### What We Should Investigate

1. **What anchor does Files.app have stored for us?** (We can't easily see this)
2. **What sequence of calls does Files.app make?** (Log every callback)
3. **Are our responses internally consistent?** (Same anchor across calls)

### Files.app's Perspective on Our Extension

When user opens Files.app → Geistty:

```
Files.app                              Our Extension
─────────                              ─────────────
"I need to show Geistty content"
        → enumerator(for: .workingSet)
        → currentSyncAnchor()          "Here's anchor ABC-5"
        ← ABC-5
        
"Do I have changes since ABC-5?"
        → enumerateChanges(from: ABC-5)
                                       "No changes"
        ← finishEnumeratingChanges(upTo: ABC-5)
        
"OK, show whatever I cached"
[User sees folder listing]

"User navigated to a folder"
        → enumerator(for: folderID)
        → enumerateItems()             "Here are 10 items"
        ← didEnumerate([items])
        ← finishEnumerating()
        
[User sees files]
```

**The "Syncing Paused" scenario might be:**

```
Files.app                              Our Extension
─────────                              ─────────────
"Let me check sync state"
        → currentSyncAnchor()          
        ← ABC-5                        [Process killed before response]
        
[No response received]
"Provider isn't responding correctly"
[Shows "Syncing Paused"]
```

OR:

```
Files.app                              Our Extension
─────────                              ─────────────
[Previous session]
        → currentSyncAnchor()          
        ← ABC-5
        
[Extension process died, restarted]
        → currentSyncAnchor()          
        ← XYZ-0                        [New random anchor!]
        
"Anchor changed from ABC-5 to XYZ-0?"
"That's a version mismatch, pausing"
```

### Key Insight: Anchor Persistence

Our anchor format is `VERSION-ITERATION` where VERSION is random on init.
If extension process dies and restarts, we generate NEW random version.
Files.app sees: `ABC-5` → `XYZ-0` - a discontinuity.

**This might be the root cause**: We persist iteration but VERSION changes on restart.

Check: Do we persist VERSION across process restarts?

**Finding**: Yes, we DO persist VERSION. The `SyncAnchorState` with both `version` and `iteration` is saved to `anchor_state.json` in the app group container.

### Potential Issue: First Install / No Persisted State

On first install or after data clear:

```
Files.app                              Our Extension
─────────                              ─────────────
"Show me Geistty"
        → enumerator(for: .workingSet)
        → currentSyncAnchor()          
        
[SyncAnchorCache.shared accessed]
[Tries to load anchor_state.json - doesn't exist]
[cachedAnchor = nil]
        
        ← nil                          "I don't have an anchor yet"
        
"Provider returned nil anchor"
"That means no sync state"
[Shows "Syncing Paused"]
```

**Then WorkingSet initializes and creates anchor, but Files.app already decided we're paused.**

### Another Scenario: Race Condition

```
Files.app                              Our Extension
─────────                              ─────────────
[Extension process starts]
        
        → currentSyncAnchor()          [Called before WorkingSet.init completes]
        ← nil                          [SyncAnchorCache has nothing yet]
        
[Meanwhile WorkingSet.init runs]
[Loads/creates anchor ABC-0]
[Updates SyncAnchorCache]

"Provider said nil, pausing"
```

### The Fix Should Be

Ensure we ALWAYS have a valid anchor before Files.app can call us:

1. **On extension init**, synchronously ensure anchor exists in persistent storage
2. **SyncAnchorCache.init()** must ALWAYS return a valid anchor (create if needed)
3. Never return `nil` from `currentSyncAnchor()`

### Fix Implemented (Jan 1, 2026)

Modified `SyncAnchorCache.init()` to create AND persist a fresh anchor if none exists:

```swift
private init() {
    if let state = WorkingSet.loadAnchorStateSync() {
        cachedAnchor = state.anchor
    } else {
        // CRITICAL: Create and persist a fresh anchor immediately
        let freshState = SyncAnchorState()
        cachedAnchor = freshState.anchor
        Self.saveAnchorStateSync(freshState)  // Persist to app group container
    }
}
```

This ensures:
- Files.app ALWAYS gets a valid anchor on first call
- The anchor is persisted before Files.app can call again
- No race condition between WorkingSet init and Files.app queries

---

## Current Status (Jan 1, 2026)

### ✅ What's Working
- **Browsing**: User can navigate into Geistty → see connections → browse remote folders
- **File listing**: Remote files/folders appear correctly with metadata (size, dates)
- **Connection folders**: SSH connections appear as browsable folders
- **Anchor persistence**: SyncAnchorCache ensures anchor exists before Files.app can query

### ❌ Outstanding Issues
- **"Syncing with Geistty Paused"** - Still appears despite various fixes
- **Changes not reflecting** - New files on server don't appear in real-time

### 🎯 Current Decision (Jan 1, 2026)
- **Architecture**: Full rebuild with SwiftData MetadataStore (not patching current code)
- **Async Strategy**: Option C - Pure async with `Task {}` (validated by Apple docs + Cryptomator)
- **Next Step**: Phase 1 - Implement MetadataStore Core

---

## 🏗️ Architecture Redesign: SwiftData-First MetadataStore (Jan 1, 2026)

### Decision: Build the Foundation Right

After extensive analysis of Blink's implementation, Apple's documentation, and our current issues, we're undertaking a **fundamental architecture redesign**. Rather than patching the current implementation, we're building a robust foundation that will support:

1. **Full read/write SFTP** - Create, modify, delete, rename, move files
2. **Offline browsing** - Cache for previously visited folders
3. **Proper change detection** - Know when remote files change
4. **Future local filesystem access** - Foundation for Ghostty local file operations
5. **Background sync** - System can update working set in background

### Why Not Just Copy Blink?

| Blink's Approach | Why We're Diverging |
|------------------|---------------------|
| Raw SQLite with `FMDB` | SwiftData is Apple's modern persistence layer with better concurrency |
| `DispatchQueue.sync` for all callbacks | Swift actors provide safer concurrency isolation |
| Class-based `WorkingSet` | Actors eliminate data race potential |
| Manual database migrations | SwiftData handles schema evolution automatically |
| Objective-C compatible patterns | Pure Swift with modern language features |

Blink's code works, but it's written for compatibility with older iOS versions and Objective-C interop. Geistty targets iOS 17+ and can leverage modern Swift features that didn't exist when Blink was architected.

### Apple's Actual Requirements (From Official Docs)

Apple's documentation gives us flexibility in HOW we implement the File Provider protocol, not just WHAT we implement:

**From [NSFileProviderSyncAnchor](https://developer.apple.com/documentation/fileprovider/nsfileprovidersyncanchor):**
> "Your file provider should populate the sync anchor with the information it needs to identify and enumerate only the changes that occurred after the synchronization point. **For example, a simple sync anchor could use the time and date of the last update** successfully downloaded from the server."

Key insight: Apple suggests **timestamps** as anchors, not strict iteration counters.

**From [NSFileProviderEnumerator.enumerateChanges](https://developer.apple.com/documentation/fileprovider/nsfileproviderenumerator/enumeratechanges(for:from:)):**
> "This method is **asynchronous**. When it's called, the enumerator gathers information about the items (perhaps from a remote server) **in the background**, and returns the results to the specified observer."

Key insight: Apple explicitly says `enumerateChanges` is async and can gather data in background.

**From [Synchronizing the File Provider Extension](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension):**
> "If your file provider doesn't explicitly track materialized items, **the working set must include all items** (documents and directories) on your remote storage."

Key insight: We can choose to include all items rather than tracking materialized items individually.

### Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           File Provider Extension                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────┐         ┌─────────────────────────────────────┐ │
│  │  WorkingSetEnumerator  │         │      FolderEnumerator               │ │
│  │   • currentAnchor()    │         │   • enumerateItems()                │ │
│  │   • enumerateChanges() │         │   • currentAnchor() → nil           │ │
│  └───────────┬────────────┘         └─────────────────┬───────────────────┘ │
│              │                                        │                      │
│              ▼                                        ▼                      │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                          MetadataStore (Actor)                         │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                    SwiftData ModelContainer                      │  │  │
│  │  │  ┌─────────────────────────────────────────────────────────┐    │  │  │
│  │  │  │  @Model CachedFileMetadata                               │    │  │  │
│  │  │  │  • itemIdentifier: String (unique)                       │    │  │  │
│  │  │  │  • connectionId: String                                  │    │  │  │
│  │  │  │  • remotePath: String                                    │    │  │  │
│  │  │  │  • filename, isDirectory, size, modificationDate         │    │  │  │
│  │  │  │  • createdAtAnchor: UInt64 (anchor when first seen)      │    │  │  │
│  │  │  │  • modifiedAtAnchor: UInt64 (anchor when last changed)   │    │  │  │
│  │  │  │  • deletedAtAnchor: UInt64? (anchor when deleted, nil=active) │  │  │
│  │  │  └─────────────────────────────────────────────────────────┘    │  │  │
│  │  │  ┌─────────────────────────────────────────────────────────┐    │  │  │
│  │  │  │  @Model SyncState                                        │    │  │  │
│  │  │  │  • currentAnchor: UInt64                                 │    │  │  │
│  │  │  │  • lastModified: Date                                    │    │  │  │
│  │  │  └─────────────────────────────────────────────────────────┘    │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                        │  │
│  │  Public API:                                                           │  │
│  │  • currentSyncAnchor() → NSFileProviderSyncAnchor                     │  │
│  │  • items(modifiedSince: UInt64) → [CachedFileMetadata]                │  │
│  │  • deletions(since: UInt64) → [NSFileProviderItemIdentifier]          │  │
│  │  • upsertItem(from: SFTPAttributes) → (item, isNew)                   │  │
│  │  • markDeleted(itemIdentifier:) → UInt64 (deletion anchor)            │  │
│  │  • incrementAnchor() → UInt64                                          │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                      │                                       │
│                                      ▼                                       │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    SFTPConnectionManager (Actor)                       │  │
│  │  • getClient(connectionId) → SFTPClient                                │  │
│  │  • Connection pooling, reconnection logic                              │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ App Group Container
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Shared SwiftData Store                             │
│  Location: group.com.geistty.fileprovider/metadata.store                    │
│  Accessible by: Main App + File Provider Extension                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Core Design Decisions

#### 1. Monotonic Anchor Counter (Not VERSION-ITERATION)

```swift
@Model
class SyncState {
    var currentAnchor: UInt64 = 0
    var lastModified: Date = .distantPast
    
    func incrementAndGet() -> UInt64 {
        currentAnchor += 1
        lastModified = Date()
        return currentAnchor
    }
    
    func toSyncAnchor() -> NSFileProviderSyncAnchor {
        var value = currentAnchor
        return NSFileProviderSyncAnchor(Data(bytes: &value, count: 8))
    }
    
    static func fromSyncAnchor(_ anchor: NSFileProviderSyncAnchor) -> UInt64? {
        guard anchor.rawValue.count == 8 else { return nil }
        return anchor.rawValue.withUnsafeBytes { $0.load(as: UInt64.self) }
    }
}
```

**Why monotonic counter instead of VERSION-ITERATION?**

| VERSION-ITERATION (Blink) | Monotonic Counter (Ours) |
|---------------------------|--------------------------|
| Requires parsing string | Direct binary comparison |
| Version reset = manual `syncAnchorExpired` | Never need manual expiration |
| Two failure modes | One failure mode |
| Harder to query "changes since X" | Simple `WHERE modifiedAtAnchor > X` |

#### 2. Anchor-Tagged Items in SwiftData

Each `CachedFileMetadata` stores WHEN it was created/modified/deleted:

```swift
@Model
class CachedFileMetadata {
    @Attribute(.unique) var itemIdentifier: String
    var connectionId: String
    var remotePath: String
    var filename: String
    var isDirectory: Bool
    var size: Int64
    var modificationDate: Date
    
    // Change tracking
    var createdAtAnchor: UInt64      // Anchor when first cached
    var modifiedAtAnchor: UInt64     // Anchor when last updated
    var deletedAtAnchor: UInt64?     // Non-nil = soft deleted
    
    // Computed: item was changed since anchor X
    func wasModifiedSince(_ anchor: UInt64) -> Bool {
        modifiedAtAnchor > anchor
    }
}
```

**Query for changes becomes trivial:**
```swift
func items(modifiedSince anchor: UInt64) async -> [CachedFileMetadata] {
    let predicate = #Predicate<CachedFileMetadata> {
        $0.modifiedAtAnchor > anchor && $0.deletedAtAnchor == nil
    }
    let descriptor = FetchDescriptor(predicate: predicate)
    return try await context.fetch(descriptor)
}

func deletions(since anchor: UInt64) async -> [String] {
    let predicate = #Predicate<CachedFileMetadata> {
        $0.deletedAtAnchor != nil && $0.deletedAtAnchor! > anchor
    }
    let descriptor = FetchDescriptor(predicate: predicate)
    let items = try await context.fetch(descriptor)
    return items.map { $0.itemIdentifier }
}
```

#### 3. Permissive Change Enumeration

Apple's docs don't require strict `iteration + 1` validation. Our approach:

```swift
func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
    Task {
        // Parse anchor
        guard let requestedAnchor = SyncState.fromSyncAnchor(anchor) else {
            // Corrupted anchor - ask system to restart
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        
        let store = await MetadataStore.shared
        let currentAnchor = await store.currentAnchor
        
        // Same anchor = no changes
        if requestedAnchor == currentAnchor {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }
        
        // ANY older anchor = report all changes since then
        // No strict "must be exactly 1 behind" validation
        let changedItems = await store.items(modifiedSince: requestedAnchor)
        let deletedIds = await store.deletions(since: requestedAnchor)
        
        // Report deletions
        if !deletedIds.isEmpty {
            let identifiers = deletedIds.map { NSFileProviderItemIdentifier($0) }
            observer.didDeleteItems(withIdentifiers: identifiers)
        }
        
        // Report updates (includes creates)
        if !changedItems.isEmpty {
            let items = changedItems.map { FileProviderItem(from: $0) }
            observer.didUpdate(items)
        }
        
        observer.finishEnumeratingChanges(
            upTo: await store.currentSyncAnchor(),
            moreComing: false
        )
    }
}
```

**Why permissive?**

| Strict (Blink: iteration + 1) | Permissive (Ours: any older) |
|-------------------------------|------------------------------|
| Forces iOS to restart sync on any gap | Gracefully handles gaps |
| Requires storing ALL changes between iterations | Just query DB |
| Memory grows with pending changes | Constant memory |
| `syncAnchorExpired` is common | `syncAnchorExpired` is rare |

#### 4. Task-Based Async (With Proper Completion)

Apple says `enumerateChanges` is asynchronous. We embrace this:

```swift
func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
    // Task runs async, calls observer methods when done
    // This is ALLOWED per Apple docs
    Task {
        // ... gather changes from SwiftData ...
        observer.didUpdate(items)
        observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
    }
}
```

**The key rule**: Always call `observer.finishEnumeratingChanges()` or `observer.finishEnumeratingWithError()`. Never leave the observer hanging.

### Why Others Don't Do This

#### Blink's Constraints

1. **iOS 11+ compatibility** - SwiftData requires iOS 17+
2. **Objective-C interop** - Blink has Obj-C components
3. **Established codebase** - Rewriting is costly for a shipped product
4. **SQLite expertise** - Their team knows FMDB well

#### Shellfish (Closed Source)

Unknown, but likely similar historical constraints.

#### Cryptomator

Uses the simpler `NSFileProviderExtension` (non-replicated), not `NSFileProviderReplicatedExtension`. Different protocol entirely.

### 🐉 Deep Analysis: Async Callbacks in File Provider (The Dragons)

Before committing to Option C (pure async with `Task {}`), we did a thorough analysis of whether calling File Provider completion handlers asynchronously is truly safe.

#### The Question

File Provider protocol methods like `enumerateChanges(for:from:)` and `enumerateItems(for:startingAt:)` receive **observer objects** that we must call to report results. The question is:

> **Must these observer methods be called synchronously (before the protocol method returns), or can they be called asynchronously (via `Task {}` or dispatch)?**

#### Evidence FOR Async Being Safe

1. **Apple's Documentation Explicitly Says Async**

   From [NSFileProviderEnumerator.enumerateChanges](https://developer.apple.com/documentation/fileprovider/nsfileproviderenumerator/enumeratechanges(for:from:)):
   > "This method is **asynchronous**. When it's called, the enumerator gathers information about the items (perhaps from a remote server) **in the background**, and returns the results to the specified observer."

   Apple literally says this method is async and can gather data in background.

2. **Apple Provides Async API Variant**

   Apple defines BOTH completion handler and async/await versions:
   ```swift
   // Completion handler (old)
   optional func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void)
   
   // Async/await (new)
   optional func currentSyncAnchor() async -> NSFileProviderSyncAnchor?
   ```
   
   The async variant proves Apple designed these APIs for async use. If async were dangerous, they wouldn't have added it.

3. **Cryptomator Uses Promise-Based Async (Production App)**

   Cryptomator's `FileProviderEnumerator.swift` uses the Promises library:
   ```swift
   adapter.enumerateItems(for: identifier, withPageToken: pageToken).then { itemList in
       observer.didEnumerate(itemList.items)
       observer.finishEnumerating(upTo: itemList.nextPageToken)
   }.catch { error in
       observer.finishEnumeratingWithError(error)
   }
   ```
   
   This calls observer methods asynchronously (when Promise resolves), exactly like our `Task {}` approach.
   **Cryptomator is a production app with millions of users.**

4. **No Documentation States Sync Requirement**

   We searched Apple's documentation extensively. There is no statement requiring synchronous completion. The observer objects are provided specifically so we CAN call them asynchronously.

#### Evidence AGAINST (Why Others Use Sync)

1. **Blink Uses DispatchQueue.sync**

   Blink's `enumerateChanges` uses `changesQueue.sync {}` - a synchronous dispatch:
   ```swift
   func enumerateChanges(for observer: ..., from anchor: ...) {
       changesQueue.sync {  // SYNCHRONOUS!
           // ... process ...
           observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
       }
   }
   ```
   
   **BUT**: This may be for thread-safety (serial queue access to shared state), not because async is forbidden. The callback still happens "synchronously" relative to the queue, but the queue itself serializes access.

2. **Historical Bugs (Unconfirmed)**

   Some have suggested iOS had bugs in earlier versions where async callbacks caused issues. We couldn't find documentation of this.

3. **Extension Lifetime Concerns**

   File Provider extensions can be killed aggressively. If we `Task {}` and the extension is killed before the task completes, the observer never gets called.
   
   **Mitigation**: Use `withTaskCancellationHandler` and ensure we always call observer on cancellation.

#### The Critical Rule

Regardless of sync vs async, Apple's documentation makes ONE thing absolutely clear:

> **You MUST call `finishEnumerating...()` or `finishEnumeratingWithError()` eventually.**

Never leaving the observer hanging is the real requirement. Sync vs async is about WHEN, not WHETHER.

#### Our Decision: Option C with Safety Rails

We're proceeding with pure async (`Task {}`), but with these safeguards:

```swift
func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
    // Critical: Always complete the observer, even on cancellation/error
    Task {
        do {
            let store = await MetadataStore.shared
            let changes = try await store.changes(since: anchor)
            
            // Report changes
            observer.didDeleteItems(withIdentifiers: changes.deletions)
            observer.didUpdate(changes.updates)
            observer.finishEnumeratingChanges(upTo: changes.newAnchor, moreComing: false)
            
        } catch is CancellationError {
            // Extension being killed - tell iOS to retry
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }
}
```

#### Dragon Watch List

Things to monitor if "Syncing Paused" persists:

1. **Timing**: If async is too slow, iOS may timeout waiting
2. **Cancellation**: Ensure cancelled tasks still call observer
3. **Reentrancy**: iOS may call methods before previous async completes
4. **Thread safety**: Observer may have thread requirements (check at runtime)

#### Summary

| Question | Answer |
|----------|--------|
| Does Apple allow async callbacks? | **Yes** - documented and API has async variant |
| Do production apps use async? | **Yes** - Cryptomator uses Promise-based async |
| Why does Blink use sync? | Thread safety, possibly historical bugs, conservatism |
| What's the real requirement? | Always call `finishEnumerating...()` eventually |
| Our approach? | Async with safety rails + monitoring |

#### Special Case: `currentSyncAnchor()` Should Stay Fast

While `enumerateItems` and `enumerateChanges` are explicitly documented as async, `currentSyncAnchor()` is a different story:

- iOS calls it frequently to check state
- It should be FAST (but not necessarily synchronous)
- Apple's async variant means we CAN use async

**Our approach**: `currentSyncAnchor()` reads from our `MetadataStore` actor, which should be sub-millisecond. Even if technically async (actor isolation), it completes instantly.

```swift
func currentSyncAnchor() async -> NSFileProviderSyncAnchor? {
    // Actor call, but no I/O - just read from memory
    await MetadataStore.shared.currentSyncAnchor
}
```

If we see issues, we can add a `nonisolated` cache with atomic access as fallback.

---

### Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| SwiftData bugs in App Extension context | Medium | Use simple schema, avoid complex relationships |
| Actor isolation overhead | Low | Modern iOS handles actors efficiently |
| Async completion timing | Medium | Always call completion, add timeouts |
| Migration from current implementation | Medium | Incremental migration, keep old code as fallback |
| SwiftData concurrency issues | Medium | Single actor owns ModelContainer, serialize access |
| **Task {} completion after extension killed** | **Medium** | **Use Task cancellation handlers, always call observer** |

### Rewards

| Benefit | Impact |
|---------|--------|
| Clean separation of concerns | Easier debugging, maintenance |
| Apple-blessed persistence layer | Future-proof, optimized by Apple |
| Type-safe queries with `#Predicate` | Compile-time correctness |
| Automatic schema migration | Less maintenance burden |
| Actor-based concurrency | No data races, no locks |
| Foundation for local filesystem | Same MetadataStore pattern works |

### Implementation Plan

#### Phase 1: MetadataStore Core (Current)
- [ ] Design SwiftData schema (`CachedFileMetadata`, `SyncState`)
- [ ] Implement `MetadataStore` actor with CRUD operations
- [ ] Add anchor-based change queries
- [ ] Unit tests for MetadataStore in isolation

#### Phase 2: Integrate with Enumerators
- [ ] Update `WorkingSetEnumerator` to use new MetadataStore
- [ ] Update `FolderEnumerator` to populate MetadataStore
- [ ] Verify "Syncing Paused" is resolved
- [ ] Integration tests with mock SFTP

#### Phase 3: Write Operations
- [ ] Implement `createItem` → MetadataStore + SFTP
- [ ] Implement `modifyItem` → MetadataStore + SFTP
- [ ] Implement `deleteItem` → MetadataStore + SFTP
- [ ] Implement `importDocument` for file uploads

#### Phase 4: Background Sync
- [ ] Polling timer with `DispatchSourceTimer` (survives backgrounding)
- [ ] Change detection: compare SFTP state to MetadataStore
- [ ] `signalEnumerator` on detected changes
- [ ] Handle extension being killed/restarted

#### Phase 5: Offline Support
- [ ] Cache recent items for offline browsing
- [ ] Queue writes when offline
- [ ] Sync queued writes when online

### API Surface: MetadataStore

```swift
actor MetadataStore {
    static let shared = MetadataStore()
    
    private let container: ModelContainer
    private var syncState: SyncState
    
    // MARK: - Sync Anchor
    
    /// Current anchor as NSFileProviderSyncAnchor
    var currentSyncAnchor: NSFileProviderSyncAnchor {
        syncState.toSyncAnchor()
    }
    
    /// Current anchor as UInt64
    var currentAnchor: UInt64 {
        syncState.currentAnchor
    }
    
    /// Increment anchor (call when changes are recorded)
    func incrementAnchor() -> UInt64 {
        syncState.incrementAndGet()
    }
    
    // MARK: - Item Operations
    
    /// Get item by identifier
    func item(id: String) async -> CachedFileMetadata?
    
    /// Get all items in a folder (for enumeration)
    func items(inFolder parentPath: String, connectionId: String) async -> [CachedFileMetadata]
    
    /// Upsert item from SFTP attributes (returns isNew flag)
    func upsert(from attributes: SFTPFileAttributes, 
                connectionId: String, 
                path: String) async -> (item: CachedFileMetadata, isNew: Bool)
    
    /// Mark item as deleted (soft delete with anchor)
    func markDeleted(id: String) async -> UInt64
    
    /// Permanently remove items deleted before anchor (cleanup)
    func purgeDeleted(before anchor: UInt64) async
    
    // MARK: - Change Queries
    
    /// Items modified since anchor (for enumerateChanges)
    func items(modifiedSince anchor: UInt64) async -> [CachedFileMetadata]
    
    /// Item identifiers deleted since anchor (for enumerateChanges)
    func deletions(since anchor: UInt64) async -> [String]
    
    // MARK: - Sync Operations
    
    /// Synchronous anchor access (for currentSyncAnchor callback)
    /// Uses nonisolated + lock for thread-safety
    nonisolated var syncAnchorSync: NSFileProviderSyncAnchor { get }
}
```

---

## Deep Analysis: "Syncing Paused" Root Causes (Jan 1, 2026)

This section documents a comprehensive analysis based on Apple's official documentation (not just Blink patterns).

### Apple's File Provider Architecture (Per Official Docs)

According to [Synchronizing the File Provider Extension](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension):

1. **Dataless vs Materialized Items**
   - **Dataless**: System only has metadata (name, size, dates)
   - **Materialized**: System has downloaded the actual content to disk

2. **The Working Set Contract**

   > "To ensure that the system applies remote updates to local copies, the working set must also include all materialized items managed by the system when using a replicated file provider."

   This is the **critical requirement** we may be violating.

3. **Two Options for Working Set Content**:
   - **Option A**: Track materialized items via `materializedItemsDidChange()` and include them in working set
   - **Option B**: Include ALL items from remote storage in working set (fallback if not tracking)

   > "If your file provider doesn't explicitly track materialized items, the working set must include all items (documents and directories) on your remote storage."

### Gap Analysis: Current Implementation vs Apple Requirements

| Apple Requirement | Our Implementation | Status |
|-------------------|-------------------|--------|
| Track materialized items via `materializedItemsDidChange()` | ✅ Implemented (registers parent folders as active) | ✓ Done |
| Enumerate materialized items via `enumeratorForMaterializedItems()` | ✅ Used inside `materializedItemsDidChange()` | ✓ Done |
| Signal BOTH container AND `.workingSet` on changes | ✅ `pollActiveFolders()` signals both | ✓ Done |
| Working set includes all materialized items | ⚠️ Tracks parent folders only, not individual items | Partial |
| Listen for `NSFileProviderMaterializedSetDidChange` notification | ❌ Not using the notification approach | N/A |
| `currentSyncAnchor()` returns real anchor | ✅ Via `SyncAnchorCache` | ✓ Done |
| `enumerateItems()` on WorkingSetEnumerator returns empty | ✅ Returns immediately with no items (per Blink) | ✓ Done |
| `enumerateChanges()` returns items iOS cares about | ⚠️ Returns identifiers, but items may not be loaded | Partial |

### Refined Root Cause Analysis

After reviewing our implementation more closely:

**What we have right**:
1. ✅ `materializedItemsDidChange()` - Implemented and tracks parent folders
2. ✅ Dual signaling - `pollActiveFolders()` signals both folder AND `.workingSet`
3. ✅ Synchronous `currentSyncAnchor()` via `SyncAnchorCache`
4. ✅ `WorkingSetEnumerator.enumerateItems()` returns empty (per Blink pattern)

**What's likely still wrong**:

1. **The polling loop never runs before extension is killed**
   - iOS kills extension process very aggressively
   - 5-second polling interval is too long
   - By the time poll would run, extension is dead

2. **Initial signal doesn't trigger proper enumeration**
   - We signal `.workingSet` on startup
   - But if there are no changes to report, iOS marks us as "paused"

3. **`enumerateChanges()` may be completing too fast with empty results**
   - If no pending changes exist, we return immediately
   - iOS might interpret rapid empty responses as "nothing to sync"

### Apple's Hidden Contract: "Up-to-date" Status

Reading between the lines in Apple's docs, **"Syncing Paused"** likely means:

> iOS has called `currentSyncAnchor()` and `enumerateChanges()` and didn't get what it expected.

The expected contract appears to be:
1. `currentSyncAnchor()` returns an anchor
2. iOS stores this anchor
3. Later, iOS calls `enumerateChanges(from: storedAnchor)`
4. We should return changes OR same anchor if no changes

**The "Paused" state likely occurs when**:
- We keep returning "no changes" but the user sees content in the folder
- iOS thinks: "If there are items but no changes, something is wrong"

### New Theory: The Working Set Must Include Items, Not Just Anchors

From Apple's docs on [Defining Your File Provider's Content](https://developer.apple.com/documentation/fileprovider/defining-your-file-provider-s-content):

> "The documents in the working set are indexed in the device's Spotlight database. The system updates this database as changes are enumerated."

**Key insight**: The working set isn't just about change tracking - iOS also uses it for Spotlight indexing. If we never provide items IN the working set, iOS can't index anything, and this may trigger the "Paused" state.

Currently our `WorkingSetEnumerator.enumerateItems()` returns **nothing** (per Blink pattern). But Apple's docs suggest the working set SHOULD contain items:

> "When the system begins indexing the working set, it calls your file provider's enumerator(for:) method, passing workingSet as the container. You must provide an enumerator that returns **all of the items and changes** for your working set."

### Blink's Actual Architecture (Deep Dive)

After reviewing Blink's code more thoroughly:

**Key Files**:
- `FileProviderReplicatedEnumerator.swift` - Contains BOTH `FileProviderReplicatedEnumerator` (for folders) AND `WorkingSetEnumerator` (for `.workingSet`)
- `WorkingSet` (class in same file) - Manages polling, change detection, anchor iteration

**Blink's WorkingSetEnumerator** (lines 189-223):
```swift
public class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    public func enumerateItems(for observer: ...) {
        log.info("enumerateItems")
        observer.finishEnumerating(upTo: nil)  // Returns NOTHING
    }
    
    public func enumerateChanges(for observer: ..., from anchor: ...) {
        self.workingSet.enumerateChanges(for: observer, from: anchor)
    }
    
    public func currentSyncAnchor(completionHandler: ...) {
        let anchor = workingSet.anchor
        completionHandler(anchor)  // Returns REAL anchor
    }
}
```

**Blink's WorkingSet.enumerateChanges()** (lines 467-510):
```swift
func enumerateChanges(for observer: ..., from anchor: ...) {
    changesQueue.sync {  // SYNCHRONOUS dispatch!
        if anchor == self.anchor {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        } else if self.anchor.iteration == anchor.iteration + 1 {
            // One iteration behind - return changes
            observer.didDeleteItems(withIdentifiers: deletions)
            observer.didUpdate(updatedItems)
            observer.finishEnumeratingChanges(upTo: self.anchor, moreComing: false)
        } else {
            // Too far behind - expired
            observer.finishEnumeratingWithError(NSFileProviderError.syncAnchorExpired)
        }
    }
}
```

### Critical Differences: Blink vs Geistty

| Aspect | Blink | Geistty |
|--------|-------|---------|
| `enumerateChanges` dispatch | `changesQueue.sync {}` (synchronous) | `Task {}` (async for item fetching) |
| Change storage | Full `FileProviderItem` objects stored | Only `NSFileProviderItemIdentifier` stored |
| `didUpdate()` call | Items already in memory, immediate | Needs async fetch from MetadataCache |
| Polling timer | `DispatchSource.makeTimerSource` (survives in background) | `Task.sleep` (cancelled when process dies) |
| Timer start | `asyncAfter(deadline: .now() + 5)` then every 5s | Immediately after init, every 5s |

### The Real Root Cause (Revised)

Based on Blink's code, the issues are:

1. **Async item fetching in `enumerateChanges()`**
   - Blink stores full `FileProviderItem` objects so it can call `observer.didUpdate()` synchronously
   - We store only identifiers and fetch items asynchronously
   - The `Task {}` in our `enumerateChanges()` may complete after enumerator is invalidated

2. **Timer mechanism**
   - Blink uses `DispatchSourceTimer` which can fire even when app isn't foreground
   - We use `Task.sleep` which requires the process to be running
   - iOS kills our extension process before our timer can fire

3. **First enumeration timing**
   - Blink delays timer start by 5 seconds (`asyncAfter(deadline: .now() + 5)`)
   - We start immediately but the first poll also waits 5 seconds
   - Same effective behavior, but our Task might be cancelled

### Next Steps to Investigate

1. **Add logging when polling would run** - Verify the 5s interval ever fires
2. **Store full items, not just identifiers** - Avoid async fetch in `enumerateChanges`
3. **Use `DispatchSourceTimer`** instead of `Task.sleep` for more reliable polling
4. **Test with immediate poll** - Poll immediately on init, not after 5s delay

### Alternative Theory: File Provider Domain State

The system maintains state per domain. Possible issue:
- Domain was created in inconsistent state
- Previous crashes left state corrupted
- Need to remove and re-add the domain

**Test**: Remove Geistty from Files.app locations, restart app, re-add.

---

## Critical Fix: Synchronous Callbacks (Jan 1, 2026)

### The Problem

File Provider `NSFileProviderEnumerator` callbacks **MUST be called synchronously**. Our implementation was using `Task {}` (async) which caused iOS to receive responses after the enumerator was invalidated.

**Symptoms observed**:
- `currentSyncAnchor` was never logged as being called
- `enumerateChanges` would complete but iOS showed "Syncing Paused"
- Enumerator was invalidated immediately after creation

### Root Cause

```swift
// WRONG - async callback
func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    Task {
        let anchor = await workingSet.currentAnchor  // Actor isolation requires await
        completionHandler(anchor)  // Called AFTER enumerator may be invalidated!
    }
}
```

Because `WorkingSet` is a Swift actor, accessing its properties requires `await`, forcing us into async context. But File Provider callbacks expect synchronous responses.

### The Fix: SyncAnchorCache

Added a thread-safe synchronous cache (`SyncAnchorCache`) that mirrors the anchor state:

```swift
/// Thread-safe cache for sync anchor - accessible synchronously
final class SyncAnchorCache {
    static let shared = SyncAnchorCache()
    private let lock = NSLock()
    private var cachedAnchor: NSFileProviderSyncAnchor?
    
    var anchor: NSFileProviderSyncAnchor? {
        lock.lock()
        defer { lock.unlock() }
        return cachedAnchor
    }
}

// Now callbacks are synchronous:
func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    if let anchor = SyncAnchorCache.shared.anchor {
        completionHandler(anchor)  // Synchronous!
    } else {
        completionHandler(nil)
    }
}
```

### Key Insight from Blink

Blink uses `DispatchQueue.sync` for all File Provider callbacks - they're ALWAYS synchronous:

```swift
// Blink's pattern - synchronous dispatch
func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
    self.changesQueue.sync {  // SYNC, not async!
        // Handle changes...
        observer.finishEnumeratingChanges(upTo: self.anchor, moreComing: false)
    }
}
```

---

## Previous Root Cause Analysis (Jan 1, 2026)

### The Problem: Change Reporting Flooding

After extensive debugging, the issue was identified:

**Bug**: `refreshFromServer()` (called during `enumerateItems()`) was calling `recordChanges()` with ALL items as "creates" on EVERY enumeration.

**Effect**:
1. User opens folder → anchor becomes `XXXX-1`, pendingChanges has N items
2. iOS calls `enumerateChanges()` → we return items, clear pendingChanges, anchor stays `XXXX-1`  
3. User refreshes → anchor becomes `XXXX-2`, pendingChanges has N items again
4. iOS has anchor `XXXX-1`, calls `enumerateChanges(from: XXXX-1)`
5. We have no pendingChanges (cleared), anchor is `XXXX-2` - mismatch!

**Fix**: Remove `recordChanges()` from `refreshFromServer()`. Changes should ONLY be recorded by the polling loop (`detectChangesInFolder()`) which properly compares server state to cache.

### Key Insight from Blink

Blink's `commitItemsInContainer()` (equivalent to our `refreshFromServer()`) does NOT call any change recording. It just stores to the database. Changes are detected SEPARATELY by `prepareChanges()` which runs on a timer and compares server state to DB.

### The Fix (Applied)

1. **`WorkingSetEnumerator.currentSyncAnchor()`** - Now returns real anchor from `WorkingSet.currentAnchor`

2. **`WorkingSetEnumerator.enumerateChanges()`** - Now:
   - Gets identifiers from `WorkingSet.getChanges(since:)`
   - Fetches actual `CachedItem` from `MetadataCache` for each identifier
   - Converts to `CachedRemoteItem` (which implements `NSFileProviderItem`)
   - Calls `observer.didUpdate([items])` with the actual items

3. **`WorkingSetEnumerator.enumerateItems()`** - Returns empty (matches Blink pattern)

### Code Flow After Fix

```
Remote file change detected
    ↓
Change detection polling (5s interval)
    ↓
WorkingSet.recordChanges() - stores identifiers, increments anchor
    ↓
WorkingSet.signalWorkingSetChange() - calls signalEnumerator(for: .workingSet)
    ↓
iOS calls WorkingSetEnumerator.enumerateChanges(from: oldAnchor)
    ↓
WorkingSet.getChanges() returns (identifiers, newAnchor, expired)
    ↓
For each identifier: MetadataCache.getItem() → CachedItem
    ↓
Convert CachedItem → CachedRemoteItem (implements NSFileProviderItem)
    ↓
observer.didDeleteItems(withIdentifiers: [...])
observer.didUpdate([CachedRemoteItem, ...])  ← ACTUAL ITEMS
observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
```

---

## Apple Documentation Summary

### Key Concepts from Apple Docs

| Concept | Description | Source |
|---------|-------------|--------|
| **Dataless vs Materialized** | Dataless = metadata only. Materialized = includes content. | [Synchronizing the File Provider Extension](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension) |
| **Working Set** | List of items particularly interesting to the user. MUST include all materialized items. | Same |
| **Sync Anchor** | Opaque token representing sync state. Used for change tracking. | [NSFileProviderEnumerator](https://developer.apple.com/documentation/fileprovider/nsfileproviderenumerator) |
| **signalEnumerator** | Notify iOS of changes. Call for both the changed container AND `.workingSet`. | Same |

### Working Set Requirements (Critical)

From Apple:
> "To ensure that the system applies remote updates to local copies, the working set must also include all materialized items managed by the system when using a replicated file provider. If your file provider doesn't explicitly track materialized items, the working set must include all items (documents and directories) on your remote storage."

**Implementation requirement**: Either:
1. Track materialized items via `materializedItemsDidChange()` and include them in working set
2. OR include ALL items in working set (what we do via polling/caching)

### Sync Anchor Contract

From Apple docs on `enumerateChanges(for:from:)`:
- Called with a sync anchor from a previous `currentSyncAnchor()` or `finishEnumeratingChanges(upTo:)`
- Must return changes since that anchor
- If anchor is too old/invalid, return `NSFileProviderError(.syncAnchorExpired)`

**CRITICAL**: `currentSyncAnchor()` returning `nil` tells iOS "no sync state known" which causes "Syncing Paused".

---

## Blink Shell Implementation Analysis

Blink is open source and has a working `NSFileProviderReplicatedExtension`. Key patterns:

### Architecture

```
Blink's Structure:
├── FileProviderReplicatedExtension.swift - Main extension
├── FileProviderReplicatedEnumerator.swift - Enumerator for folders
├── FileProviderReplicatedExtension+Helpers.swift - Item operations
├── WorkingSetDatabase.swift - SQLite-backed working set
└── WorkingSet (in Enumerator file) - Change tracking class
```

### Sync Anchor Pattern (from Blink)

```swift
// WorkingSet anchor format: "VERSION-ITERATION"
var anchor: NSFileProviderSyncAnchor {
    NSFileProviderSyncAnchor("\(anchorVersion)-\(anchorIteration)".data(using: .utf8)!)
}

// anchorVersion: Random 4-char string, renewed on database reset
// anchorIteration: Integer incremented on each change batch
```

### Key Patterns

1. **Folder Enumerator returns `nil` for `currentSyncAnchor()`**
   ```swift
   // FileProviderReplicatedEnumerator.swift:172-183
   public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
       log.info("currentSyncAnchor requested")
       completionHandler(nil)  // Folder enumerators return nil
   }
   ```

2. **WorkingSetEnumerator returns the actual anchor**
   ```swift
   // FileProviderReplicatedEnumerator.swift:215-218
   public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
       let anchor = workingSet.anchor
       log.info("currentSyncAnchor \(anchor.string)")
       completionHandler(anchor)  // WorkingSet returns real anchor
   }
   ```

3. **enumerateChanges for WorkingSet** (lines 467-510)
   - Same anchor = return same anchor, no changes
   - One iteration behind = return changes, increment anchor
   - More than one behind = `syncAnchorExpired`

4. **Folder enumerators don't track changes individually**
   ```swift
   // FileProviderReplicatedEnumerator.swift:137-152
   public func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
       log.info("No changes at enumerator")
       observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
   }
   ```

5. **Polling timer for active folders** (5 second interval)
   ```swift
   // WorkingSet.resumeChangesTimerEvery(seconds: 5)
   DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5) {
       self.workingSet.resumeChangesTimerEvery(seconds: 5)
   }
   ```

6. **signalEnumerator for `.workingSet`** after changes
   ```swift
   func signalEnumerator() {
       self.fpm?.signalEnumerator(for: .workingSet) { error in
           if let error = error {
               self.log.error("signalEnumerator failed: \(error)")
           }
       }
   }
   ```

---

## Geistty's Implementation

### Current Architecture

```
Geistty's Structure:
├── FileProviderExtension.swift
│   ├── SFTPConnectionManager (actor) - SSH/SFTP connection pool
│   ├── FileProviderExtension (NSFileProviderReplicatedExtension)
│   ├── RootItem - Root container item
│   ├── ConnectionFolderItem - SSH connection as folder
│   ├── RemoteItem - Remote file/folder item
│   ├── CachedRemoteItem - Item from cache
│   ├── WorkingSetEnumerator - Working set enumerator
│   ├── ConnectionsEnumerator - Enumerates connections at root
│   ├── RemoteEnumerator - Enumerates remote folder contents
│   └── MaterializedItemsObserver - Tracks materialized items
├── WorkingSet.swift - Sync anchor and change management
├── CachedItem.swift - SwiftData model for cached metadata
└── MetadataCache.swift - Thread-safe SwiftData cache
```

### Domain Architecture

**Single domain** with connections as subfolders (same as Shellfish):
- Domain: `geistty`
- Root: Shows saved SSH connections as folders
- Each connection folder: Maps to remote SFTP root

### Item Identifier Format

```
Root:           .rootContainer
Connection:     "conn:<profileId>"
Remote file:    "conn:<profileId>:path:<remotePath>"
```

---

## Current Issues Analysis

### Issue 1: "Syncing with Geistty Paused"

**Likely causes:**
1. ❌ `ConnectionsEnumerator.currentSyncAnchor()` was returning `nil`
2. ❌ `RemoteEnumerator.currentSyncAnchor()` was returning `nil` before first enumeration
3. ❌ `WorkingSetEnumerator.enumerateChanges()` was returning `syncAnchorExpired` too often

**Blink's approach:**
- Folder enumerators return `nil` - iOS just re-enumerates
- Only WorkingSetEnumerator returns a real anchor
- `syncAnchorExpired` only when truly too far behind

### Issue 2: "Read-Only"

**Likely causes:**
1. ❌ `capabilities` not including write permissions
2. ❌ Error during `createItem`/`modifyItem`/`deleteItem` 
3. ❌ Missing `NSExtensionFileProviderSupportsPickingFolders` (added)

---

## Correct Implementation

### Enumerator Sync Anchor Rules (Matches Blink's Pattern)

| Enumerator | `currentSyncAnchor()` | `enumerateChanges()` |
|------------|----------------------|---------------------|
| ConnectionsEnumerator | `nil` | Return same anchor, no changes |
| RemoteEnumerator | `nil` | Return same anchor, no changes |
| WorkingSetEnumerator | Real anchor (VERSION-ITERATION) | Proper change tracking |

**Rationale** (from Blink's FileProviderReplicatedEnumerator.swift:172-183):
- Folder enumerators return `nil` for `currentSyncAnchor()` - iOS just re-enumerates when needed
- Only WorkingSetEnumerator returns a real anchor for change tracking
- This separates "folder contents" from "change tracking"
- iOS calls `enumerateItems()` when user navigates to a folder
- iOS calls `enumerateChanges()` on WorkingSet to detect changes across the domain

### Sync Anchor Format

```swift
// WorkingSet anchor: "VERSION-ITERATION"
// VERSION: Random string, changes on reset/incompatible state
// ITERATION: Integer, increments on each change batch

struct SyncAnchorState {
    let version: String      // e.g., "ABCD"
    let iteration: Int       // e.g., 5
    
    var anchorData: Data {
        "\(version)-\(iteration)".data(using: .utf8)!
    }
}
```

### Change Flow (Corrected)

```
1. Extension initialized
   → WorkingSet.anchor = "ABCD-0" (loaded from persistence or new)

2. User navigates to folder
   → RemoteEnumerator.enumerateItems()
   → Items fetched from server
   → Items cached to MetadataCache
   → NO recordChanges() call - anchor stays "ABCD-0"
   → Items returned to observer

3. Polling timer fires (every 5 seconds)
   → pollActiveFolders() called
   → For each active folder: detectChangesInFolder()
   → Compares server state to MetadataCache
   → If changes found: recordChanges()
   → anchor becomes "ABCD-1"
   → signalEnumerator(for: .workingSet)

4. iOS calls WorkingSetEnumerator.enumerateChanges(from: "ABCD-0")
   → getChanges() returns pending changes
   → observer.didUpdate([items])
   → observer.finishEnumeratingChanges(upTo: "ABCD-1")
   → pendingChanges cleared

5. Next poll detects no changes
   → No recordChanges() call
   → Anchor stays at "ABCD-1"

6. iOS calls enumerateChanges(from: "ABCD-1")
   → getChanges() returns no changes (same anchor)
   → observer.finishEnumeratingChanges(upTo: "ABCD-1")
```

**Key Principle**: `recordChanges()` should ONLY be called when actual changes are detected by comparing server to cache, NOT on every enumeration.

---

## Implementation Checklist

### 🏗️ Architecture Redesign (SwiftData MetadataStore)

#### Phase 1: MetadataStore Core
- [ ] Create `CachedFileMetadata` SwiftData model with anchor tracking
- [ ] Create `SyncState` SwiftData model with monotonic counter
- [ ] Implement `MetadataStore` actor with CRUD operations
- [ ] Add `items(modifiedSince:)` and `deletions(since:)` queries
- [ ] Add `nonisolated syncAnchorSync` for synchronous access
- [ ] Unit tests for MetadataStore in isolation
- [ ] Store in App Group container for extension access

#### Phase 2: Integrate with Enumerators
- [ ] Update `WorkingSetEnumerator` to use new MetadataStore
- [ ] Implement permissive `enumerateChanges()` (any older anchor works)
- [ ] Update `FolderEnumerator` to populate MetadataStore on enumeration
- [ ] Remove old `WorkingSet` actor and `SyncAnchorCache`
- [ ] Verify "Syncing Paused" is resolved
- [ ] Integration tests with mock SFTP

#### Phase 3: Write Operations
- [ ] Implement `createItem` → MetadataStore + SFTP upload
- [ ] Implement `modifyItem` → MetadataStore + SFTP update
- [ ] Implement `deleteItem` → MetadataStore soft-delete + SFTP rm
- [ ] Implement `importDocument` for file drag-and-drop uploads
- [ ] Handle conflicts (local vs remote modification)

#### Phase 4: Background Sync & Polling
- [ ] Replace `Task.sleep` with `DispatchSourceTimer` (survives backgrounding)
- [ ] Change detection: compare SFTP `readdir` to MetadataStore
- [ ] Efficient delta detection (by mtime/size, not full content)
- [ ] `signalEnumerator(for: .workingSet)` on detected changes
- [ ] Handle extension being killed/restarted gracefully

#### Phase 5: Offline Support & Polish
- [ ] Cache file metadata for offline folder browsing
- [ ] Queue write operations when offline
- [ ] Sync queued writes when connection restored
- [ ] Add "last synced" indicator in UI
- [ ] Purge old soft-deleted items (`purgeDeleted(before:)`)

### ✅ Previous Implementation (Legacy - Being Replaced)
- [x] Single domain with connections as subfolders
- [x] WorkingSet actor for sync anchor management
- [x] MetadataCache with SwiftData (basic version)
- [x] Polling for active folders (5 sec interval)
- [x] `materializedItemsDidChange()` implementation
- [x] `NSExtensionFileProviderSupportsPickingFolders` in Info.plist
- [x] App Group shared between app and extension
- [x] Folder enumerators return `nil` for `currentSyncAnchor()`
- [x] `WorkingSetEnumerator.currentSyncAnchor()` returns real anchor
- [x] `WorkingSetEnumerator.enumerateItems()` returns no items

### 🔧 Known Issues (To Be Fixed by Redesign)
- [x] "Syncing Paused" error - **FIX IMPLEMENTED** (Jan 1, 2026): Added `signalErrorsResolved()` in extension after SFTP connection. Needs device testing.
- [ ] Timer dies with extension process - needs `DispatchSourceTimer`
- [ ] Async item fetch in `enumerateChanges()` - needs items pre-stored
- [ ] No write operations implemented

---

## Testing Checklist

### Basic Functionality
- [ ] Connections appear in Files.app
- [ ] Can navigate into connection folders
- [ ] Files and folders display correctly
- [ ] File icons match content types

### Sync State
- [ ] No "Syncing Paused" message - **Fix implemented Jan 1, needs device test**
- [ ] No "Read-Only" message
- [ ] Changes on remote appear after polling interval
- [ ] No excessive re-enumeration (check logs)

### Write Operations
- [ ] Create new folder works
- [ ] Create new file works
- [ ] Rename file/folder works
- [ ] Delete file/folder works
- [ ] Move file/folder works

### Error Handling
- [ ] Offline shows appropriate error
- [ ] Auth failure shows "Authentication Required"
- [ ] Server unreachable shows correct message

---

## Debug Logging

### Console.app Filter
```
subsystem:com.geistty category:FP-EXT
```

### Device Logging
```bash
xcrun devicectl device process launch --device <device-id> --console com.geistty.app 2>&1 | grep -E "(FP-EXT|WS-ENUM|SFTP)" --line-buffered
```

### Key Log Points
- `[FP-EXT]` - FileProviderExtension
- `[WS-ENUM]` - WorkingSetEnumerator  
- `[WorkingSet]` - WorkingSet actor
- `[SFTP]` - SFTP operations

---

## References

### Apple Documentation
- [NSFileProviderReplicatedExtension](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension)
- [NSFileProviderEnumerator](https://developer.apple.com/documentation/fileprovider/nsfileproviderenumerator)
- [Synchronizing the File Provider Extension](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension)
- [Defining Your File Provider's Content](https://developer.apple.com/documentation/fileprovider/defining-your-file-provider-s-content)

### Working Implementations
- [Blink Shell](https://github.com/blinksh/blink) - BlinkFileProvider/
- Shellfish (closed source, but uses same architecture per user)

### WWDC Sessions
- WWDC 2021: [Meet the new Document-Based App](https://developer.apple.com/wwdc21/10052)
- WWDC 2019: [What's New in File Management and Quick Look](https://developer.apple.com/wwdc19/719)

---

## Revision History

| Date | Changes |
|------|---------|
| Jan 1, 2026 | **"Syncing Paused" Fix**: Added cache-first approach in `item(for:)`, `signalErrorsResolved()` in extension after SFTP connection. Root cause: resolvable errors (`.notAuthenticated`, `.serverUnreachable`) persist until `signalErrorResolved()` is called. Extension was throwing errors but never clearing them. |
| Jan 1, 2026 | **Async Callback Analysis Complete**: Deep analysis confirms `Task {}` is safe for File Provider callbacks. Apple docs explicitly say async, Apple provides async API variant, Cryptomator (production app) uses Promise-based async. Added "Deep Analysis: Async Callbacks" section with evidence and safety rails. Ready for Phase 1 implementation. |
| Jan 1, 2026 | **Architecture Redesign Decision**: SwiftData MetadataStore with monotonic anchor counter, permissive change enumeration, full implementation plan. Moving away from Blink's strict iteration validation toward Apple best practices. |
