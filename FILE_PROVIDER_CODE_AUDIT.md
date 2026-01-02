# File Provider Code Audit

**Date:** January 2, 2026  
**Purpose:** Document technical debt, duplicate code, and cleanup opportunities  
**Status:** ✅ PHASE 1 CLEANUP COMPLETE

---

## Cleanup Summary (Jan 2, 2026)

### Files Deleted

| File | Lines | Contents |
|------|-------|----------|
| `WorkingSet.swift` | 542 | `SyncAnchorCache`, `SyncAnchorState`, `ActiveFolder`, VERSION-ITERATION anchors |
| `SimpleWorkingSetEnumerator.swift` | 73 | Unused "always no changes" enumerator |

**Total:** 615 lines of dead code removed

### Project File Updated

- Removed all `WorkingSet.swift` references from `project.pbxproj`
- Removed all `SimpleWorkingSetEnumerator.swift` references from `project.pbxproj`
- Tests pass: All 122 tests ✅

---

## Remaining Cleanup (Phase 2)

### 1. Debug Logging Duplication

4 duplicate `debugLog()` functions exist in `FileProviderExtension.swift`:
- Line 79: `SFTPConnectionManager.debugLog()`
- Line 365: `FileProviderExtension.debugLog()`
- Line 1167: `ConnectionsEnumerator.debugLog()`  
- Line 1393: `RemoteEnumerator.debugLog()`

**Recommendation:** Consolidate into single shared function or use `Logger` consistently.

### 2. Item Identifier Helpers

Two parallel implementations:
- `MetadataStore.swift`: `ItemIdentifier` enum
- `CachedItem.swift`: Static methods

**Recommendation:** Use `ItemIdentifier` enum everywhere.

### 3. NSFileProviderItem Implementations

Three separate item classes with duplicate property implementations:
- `CachedMetadataItem` (MetadataStoreEnumerator.swift)
- `ConnectionFolderItem` (FileProviderExtension.swift)
- `RemoteFileItem` (FileProviderExtension.swift)

**Recommendation:** Consider shared protocol extension for common properties.

---

## Original Analysis (Pre-Cleanup)

The File Provider implementation had accumulated significant technical debt from iterative troubleshooting:

- **3 different enumerator implementations** (only 1 was used) → ✅ FIXED
- **2 different anchor cache systems** → ✅ FIXED (deleted SyncAnchorCache)
- **2 different anchor formats** → ✅ FIXED (only UInt64 remains)
- **Duplicate persistence files** → ✅ FIXED (deleted anchor_state.json code)
- **Dead code in WorkingSet.swift** → ✅ DELETED (542 lines)
- **Inconsistent patterns** → Partially addressed

---

## 1. Enumerator Duplication ✅ RESOLVED

### Before

| File | Class | Used? | Purpose |
|------|-------|-------|---------|
| `FileProviderCore/MetadataStoreEnumerator.swift` | `MetadataStoreEnumerator` | ✅ **YES** | Working set with UInt64 anchors |
| `FileProviderCore/SimpleWorkingSetEnumerator.swift` | `SimpleWorkingSetEnumerator` | ❌ NO | "Always no changes" approach |
| `GeisttyFileProvider/WorkingSet.swift` | (within `WorkingSet` actor) | ❌ NO | Legacy VERSION-ITERATION approach |

### After

| File | Class | Used? | Purpose |
|------|-------|-------|---------|
| `FileProviderCore/MetadataStoreEnumerator.swift` | `MetadataStoreEnumerator` | ✅ **YES** | Working set with UInt64 anchors |

**Action Taken:** Deleted `SimpleWorkingSetEnumerator.swift` and `WorkingSet.swift`

### Evidence

In `FileProviderExtension.swift` line ~910:
```swift
if containerItemIdentifier == .workingSet {
    return MetadataStoreEnumerator()  // ← ONLY this is used
}
```

### Recommendation

**DELETE:**
- `SimpleWorkingSetEnumerator.swift` - Unused alternative approach
- Most of `WorkingSet.swift` - Legacy code with VERSION-ITERATION anchors

---

## 2. Anchor Cache Duplication

### Current State

| Location | Class | Format | Used? |
|----------|-------|--------|-------|
| `MetadataStore.swift` | `MetadataAnchorCache` | UInt64 (8 bytes) | ✅ **YES** |
| `WorkingSet.swift` | `SyncAnchorCache` | VERSION-ITERATION string | ❌ NO |

### `MetadataAnchorCache` (KEEP)

```swift
final class MetadataAnchorCache: @unchecked Sendable {
    static let shared = MetadataAnchorCache()
    private var _currentAnchor: UInt64 = 0
    // Persists to: sync_anchor.dat (8 bytes)
}
```

### `SyncAnchorCache` (DELETE)

```swift
final class SyncAnchorCache {
    static let shared = SyncAnchorCache()
    private var cachedAnchor: NSFileProviderSyncAnchor?
    // Persists to: anchor_state.json (VERSION-ITERATION string)
}
```

### Risk

Both caches write to DIFFERENT files:
- `MetadataAnchorCache` → `sync_anchor.dat`
- `SyncAnchorCache` → `anchor_state.json`

iOS may have cached the old VERSION-ITERATION anchor, causing format confusion.

### Recommendation

**DELETE:**
- `SyncAnchorCache` class entirely
- `anchor_state.json` persistence code
- All references to VERSION-ITERATION format

---

## 3. WorkingSet.swift Analysis

### What's In There

| Component | Lines | Used? | Notes |
|-----------|-------|-------|-------|
| `SyncAnchorState` struct | 25-73 | ❌ NO | VERSION-ITERATION anchor format |
| `ActiveFolder` struct | 78-95 | ❌ NO | Old tracking method |
| `DetectedChanges` struct | 100-118 | ❌ NO | In-memory change tracking |
| `SyncAnchorCache` class | 125-200 | ❌ NO | Duplicate of MetadataAnchorCache |
| `WorkingSet` actor | 207-500+ | ❌ NO | Entire actor unused |
| `PersistedAnchorState` | 495+ | ❌ NO | anchor_state.json format |
| `PersistedActiveFolder` | 490+ | ❌ NO | active_folders.json format |

### Entire File is Dead Code

Nothing in `WorkingSet.swift` is called by the active code path:
- `MetadataStoreEnumerator` uses `MetadataStore` and `MetadataAnchorCache`
- `FileProviderExtension.enumerator(for:)` returns `MetadataStoreEnumerator()`
- No code path instantiates `WorkingSet` actor

### Recommendation

**DELETE ENTIRE FILE** - 542 lines of dead code

---

## 4. Persistence File Duplication

### Files in App Group Container

| File | Format | Written By | Read By | Used? |
|------|--------|------------|---------|-------|
| `sync_anchor.dat` | UInt64 (8 bytes) | MetadataAnchorCache | MetadataAnchorCache | ✅ YES |
| `anchor_state.json` | JSON {version, iteration} | SyncAnchorCache | SyncAnchorCache | ❌ NO |
| `active_folders.json` | JSON array | WorkingSet actor | WorkingSet actor | ❌ NO |
| `MetadataStore.sqlite` | SwiftData | MetadataStore | MetadataStore | ✅ YES |
| `fileprovider_debug.log` | Text | Various | Debug only | ⚠️ Debug |

### Recommendation

**DELETE persistence code for:**
- `anchor_state.json` 
- `active_folders.json`

**KEEP:**
- `sync_anchor.dat`
- `MetadataStore.sqlite`

---

## 5. Debug Logging Duplication

### `debugLog` Functions

Every class has its own copy:
- `FileProviderExtension.debugLog()`
- `SFTPConnectionManager.debugLog()`
- `ConnectionsEnumerator.debugLog()`
- `RemoteEnumerator.debugLog()`
- `WorkingSet.debugLog()`

All write to `fileprovider_debug.log` with slightly different formats.

### Recommendation

**CONSOLIDATE** into a single shared function or use `Logger` consistently.

---

## 6. Item Identifier Helpers Duplication

### Current State

| Location | Functions |
|----------|-----------|
| `MetadataStore.swift` | `ItemIdentifier` enum with static helpers |
| `SFTP/CachedItem.swift` | `CachedItem` struct with static helpers |
| Various files | Inline parsing logic |

### Example: Connection Root ID

```swift
// In MetadataStore.swift
static func connectionRoot(_ connectionId: String) -> String {
    "conn:\(connectionId)"
}

// In CachedItem.swift
static func connectionRootId(_ connectionId: String) -> String {
    "conn:\(connectionId)"
}
```

### Recommendation

**CONSOLIDATE** into single `ItemIdentifier` helper used everywhere.

---

## 7. NSFileProviderItem Implementations

### Current State

| Class | Location | Used For |
|-------|----------|----------|
| `CachedMetadataItem` | MetadataStoreEnumerator.swift | Working set items |
| `ConnectionFolderItem` | FileProviderExtension.swift | Connection root folders |
| `RemoteFileItem` | FileProviderExtension.swift | Remote files/folders |
| (inline in tests) | Various test files | Test mocks |

### Duplication

All implement the same properties with slight variations:
- `itemVersion` computation
- `isDownloaded`/`isUploaded` logic
- `capabilities`

### Recommendation

**CONSIDER** shared base class or protocol extension for common properties.

---

## 8. Cleanup Action Plan

### Phase 1: Delete Dead Code

1. Delete `SimpleWorkingSetEnumerator.swift`
2. Delete `WorkingSet.swift` (entire file - 542 lines)
3. Remove from Xcode project

### Phase 2: Clean Up MetadataStore.swift

1. Remove any references to `SyncAnchorCache`
2. Verify `MetadataAnchorCache` is sole anchor cache
3. Clean up commented/dead code

### Phase 3: Consolidate Item Identifiers

1. Keep `ItemIdentifier` enum in `MetadataStore.swift`
2. Update all code to use it
3. Delete `CachedItem` identifier helpers (keep caching logic)

### Phase 4: Clean Up Debug Logging

1. Create shared `FileProviderLogger`
2. Replace all `debugLog` functions
3. Or: Remove file logging, use only `Logger`

### Phase 5: Clean Up Persistence

1. Delete `anchor_state.json` handling code
2. Delete `active_folders.json` handling code
3. Document which files are actually used

---

## 9. Risk Assessment

### Deleting WorkingSet.swift

**Risk:** LOW
- Not instantiated anywhere in active code
- All references are in comments or documentation
- Tests use MetadataStore directly

### Deleting SimpleWorkingSetEnumerator.swift

**Risk:** LOW  
- Was an alternative approach never adopted
- Xcode project includes it but never used

### Deleting SyncAnchorCache

**Risk:** MEDIUM
- Must ensure no code path still references it
- Must clean up `anchor_state.json` file on devices

---

## 10. Files to Modify/Delete

### DELETE (5 files)

| File | Lines | Reason |
|------|-------|--------|
| `WorkingSet.swift` | 542 | Entirely dead code |
| `SimpleWorkingSetEnumerator.swift` | 73 | Unused alternative |
| `project.pbxproj.backup` | ? | Build artifact |

### MODIFY (major cleanup)

| File | Changes |
|------|---------|
| `MetadataStore.swift` | Remove dead code references |
| `FileProviderExtension.swift` | Remove WorkingSet references |
| `FileProviderDomainManager.swift` | Clean up signaling |

### KEEP (core functionality)

| File | Purpose |
|------|---------|
| `MetadataStoreEnumerator.swift` | Working set enumerator |
| `MetadataStore.swift` | SwiftData storage + MetadataAnchorCache |
| `CachedFileMetadata.swift` | SwiftData model |
| `SyncState.swift` | Anchor persistence model |
| `ActiveFolderRecord.swift` | Folder tracking model |

---

## 11. Test Impact

### Tests to Update

- `MetadataStoreTests.swift` - May reference deleted code
- `FileProviderTests.swift` - Has `SyncAnchorCache` tests
- `FileProviderExtensionTests.swift` - Has various integration tests

### Tests to Delete

Any tests for:
- `SyncAnchorCache`
- `WorkingSet` actor
- `SimpleWorkingSetEnumerator`
- VERSION-ITERATION anchor format

---

## Conclusion

The File Provider implementation works but carries ~700+ lines of dead code from previous approaches. A focused cleanup will:

1. **Reduce confusion** - Single clear implementation
2. **Prevent bugs** - No risk of accidentally using dead code
3. **Improve maintainability** - Less code to understand
4. **Fix potential anchor issues** - Single UInt64 format everywhere

**Estimated cleanup effort:** 2-4 hours to safely delete dead code and update tests.
