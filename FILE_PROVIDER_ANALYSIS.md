# File Provider v1: Holistic Analysis

**Date:** January 5, 2026  
**Status:** ✅ Option B implemented - simplified to single source of truth

## Summary

Originally ~2,967 lines of code across 6 files with triple anchor storage. After Option B simplification:
- **Removed:** `MetadataAnchorCache` class and `sync_anchor.dat` file persistence
- **Result:** SwiftData is now the ONLY source of truth for anchors
- **Tests:** All passing on simulator

---

## Option B Implementation (Jan 5, 2026)

### What Was Removed

| Component | Lines | Why Removed |
|-----------|-------|-------------|
| MetadataAnchorCache class | ~130 | Redundant - SwiftData is source of truth |
| sync_anchor.dat persistence | ~50 | File-based backup no longer needed |
| Cache refresh calls | ~30 | Anchor updates automatically on upsert |

### What Changed

1. **MetadataStore.swift**: Now ~550 lines (was ~968)
   - Removed `MetadataAnchorCache` class entirely
   - Removed file-based `sync_anchor.dat` persistence
   - `currentAnchor` and `currentSyncAnchor` query SwiftData directly

2. **MetadataStoreEnumerator.swift**: Now uses `Task{}` pattern
   - `currentSyncAnchor()` queries `MetadataStore.shared` via `Task{}`
   - Apple docs allow async callbacks for this method
   - No separate cache layer

3. **Tests Updated**: All `MetadataAnchorCache` references replaced
   - Tests now query `MetadataStore.shared` directly
   - Async expectations added where needed

### Why This Should Fix "Syncing Paused"

The **root cause hypothesis** was anchor desync between three sources:
1. SwiftData `SyncState` (ground truth)
2. `MetadataAnchorCache` (in-memory cache)
3. `sync_anchor.dat` (file backup)

With Option B, there's only ONE source: SwiftData. No desync possible.

---

## Original Analysis (Pre-Option B)

### File Inventory (Original)

| File | Lines | Purpose |
|------|-------|---------|
| FileProviderExtension.swift | 1,428 | Main extension + 5 item types + 3 enumerators + connection manager |
| MetadataStore.swift | 968 | SwiftData actor + anchor cache + change queries |
| MetadataStoreEnumerator.swift | 241 | Working set enumerator + CachedMetadataItem wrapper |
| CachedFileMetadata.swift | 190 | SwiftData @Model |
| SyncState.swift | 76 | SwiftData @Model for anchor |
| ActiveFolderRecord.swift | 64 | SwiftData @Model for polling |
| **Total** | **2,967** | |

### What Blink Uses for Comparison

| Component | Lines | Purpose |
|-----------|-------|---------|
| FileProviderReplicatedExtension.swift | ~600 | Main extension + WorkingSet instantiation |
| FileProviderReplicatedEnumerator.swift | ~600 | Enumerator + SQLite-backed WorkingSet |
| **Total** | **~1,200** | |

**We have 2.5x the code for the same functionality.**

---

## Component-by-Component Breakdown

### 1. Item Types (5 vs Blink's 1)

```
Our implementation:
├── RootItem (class)
├── ConnectionFolderItem (class) 
├── RemoteItem (class)
├── CachedMetadataItem (class)
└── CachedFileMetadata (@Model)

Blink's implementation:
└── FileProviderReplicatedItem (struct)
```

**Why we have 5:**
- RootItem: The Geistty root folder
- ConnectionFolderItem: Each SSH connection appears as a folder
- RemoteItem: Server response turned into item (used in browse)
- CachedMetadataItem: Wrapper around CachedFileMetadata for enumerateChanges
- CachedFileMetadata: The SwiftData persistence model

**Why Blink has 1:**
Blink uses a single struct that can represent any item. The item identifier encodes what type it is.

**Verdict:** We could collapse to 2-3 types. The RemoteItem/CachedMetadataItem split is confusing.

### 2. Enumerators (3 vs Blink's pattern)

```
Our implementation:
├── ConnectionsEnumerator (lists SSH connections at root)
├── RemoteEnumerator (fetches from SFTP for browsing)
└── MetadataStoreEnumerator (working set change tracking)

Blink's implementation:
├── FileProviderReplicatedEnumerator (browsing + change prep)
└── WorkingSet (owns state, does change tracking)
```

**Problem:** Our three enumerators have subtle inconsistencies:
- `ConnectionsEnumerator.currentSyncAnchor()` returns `nil`
- `RemoteEnumerator.currentSyncAnchor()` returns `nil`
- `MetadataStoreEnumerator.currentSyncAnchor()` returns the actual anchor

**Blink's approach:** Only the WorkingSet returns an anchor. Folder enumerators don't participate in change tracking.

**Verdict:** Our design matches Blink's intent but the split is confusing.

### 3. Anchor/State Management (3 mechanisms vs Blink's 1)

```
Our implementation:
├── SyncState (@Model in SwiftData)
├── MetadataAnchorCache (singleton, NSLock-protected)
└── sync_anchor.dat (file-based persistence)

Blink's implementation:
└── WorkingSetDatabase (SQLite, one table with anchor column)
```

**Why we have 3:**
1. `SyncState` - SwiftData wanted an @Model
2. `MetadataAnchorCache` - File Provider needs synchronous access, SwiftData is async
3. `sync_anchor.dat` - The cache needs to survive across extension launches

**Problem:** Three sources of truth = potential for desync. The MetadataAnchorCache has its own persistence file AND reads from SwiftData.

**Verdict:** This is the most suspicious area. Blink has ONE database, ONE anchor.

### 4. Change Detection (Polling)

```
Our implementation:
├── startPolling() in FileProviderExtension init
├── pollActiveFolders() every 5 seconds
├── detectChangesInFolderNew() per folder
└── ActiveFolderRecord tracking

Blink's implementation:
├── resumeChangesTimerEvery() in WorkingSet
├── prepareChanges() per active enumerator
└── PollCoordinator tracks active folders
```

**This is similar.** Both poll every 5 seconds. Both track "active folders."

**Our twist:** We removed `unregisterActiveFolder()` from `invalidate()` to keep folders registered. Blink does the same (LRU eviction, not eager unregister).

### 5. Item Caching / Metadata Store

```
Our implementation:
├── MetadataStore (actor)
├── CachedFileMetadata (@Model)
│   └── Soft deletes via deletedAtAnchor
└── upsertBatch() for change detection

Blink's implementation:
├── WorkingSetDatabase (SQLite)
└── Rows with deleted flag
```

**This is equivalent.** Both cache file metadata with soft deletes.

**Problem:** Our MetadataStore is 968 lines. That's a lot for what it does.

### 6. Connection Management

```
Our implementation:
├── SFTPConnectionManager (actor, singleton)
├── FileProviderDomainManager (shared container access)
└── getClient(for:) with deduplication

Blink's implementation:
├── BlinkFileProviderLocal (creates connections)
└── Connection pooling in core
```

**This is reasonable.** We need to share SFTP connections.

---

## Root Cause Theories

### Theory 1: Anchor Desync

Three sources of truth for anchor state:
1. `SyncState` in SwiftData (async)
2. `MetadataAnchorCache` in memory (sync)
3. `sync_anchor.dat` on disk

If these desync, iOS might see an anchor that doesn't match our data.

**Test:** Add logging to see if anchor values match across all three.

### Theory 2: enumerateChanges Never Returns Items

We correctly return items in `enumerateChanges`, but maybe iOS never calls it because:
- The initial `currentSyncAnchor()` returns a value iOS already has
- iOS thinks it's up-to-date, never asks for changes
- "Syncing Paused" might mean "nothing to sync" displayed incorrectly

**Test:** Log every `enumerateChanges` call and what we return.

### Theory 3: Missing Item Property

`NSFileProviderItem` requires specific properties for replicated extensions:
- `itemVersion` ✅ (we have this)
- `isDownloaded` ✅ (we have this)
- `capabilities` ✅ (we have this)

But maybe we're missing something or returning invalid values.

**Test:** Compare every property of our items with Blink's.

### Theory 4: Domain Registration Issue

"Syncing Paused" might mean the domain isn't properly registered. But:
- We see the "Geistty" folder in Files.app
- We can browse connections
- This doesn't seem right

---

## Cool Stuff We Built (Worth Preserving)

1. **Actor-based MetadataStore** - Thread-safe by design
2. **SwiftData persistence** - Modern, typed storage
3. **Soft deletes for change tracking** - Clean deletion detection
4. **Connection pooling** - SFTPConnectionManager deduplication
5. **Debug logging** - FileProviderDebugLog writes to shared container

---

## Recommendation

### Option A: Debug First
1. Add comprehensive logging to all three anchor sources
2. Add logging to every iOS callback (what does iOS actually call?)
3. Compare our item properties to Blink's exactly
4. **Risk:** More time in the rabbit hole

### Option B: Simplify to Blink's Pattern
1. Replace SwiftData with SQLite (one source of truth)
2. Replace 3 enumerators with 2 (folder + WorkingSet)
3. Collapse item types to 1 or 2
4. **Risk:** Lose some infrastructure for future features

### Option C: Minimal MVP
1. Delete everything except basic browsing
2. Get "browse files in Files.app" working perfectly
3. Add change tracking only after browse works
4. **Risk:** Lose the bidirectional vision temporarily

### My Recommendation: **Option B**

We don't need to nuke from orbit. The architecture is sound-ish. The problem is likely in the anchor/state management complexity.

Specifically:
1. Kill `MetadataAnchorCache` and `sync_anchor.dat`
2. Use `SyncState` directly (accept the async complexity)
3. Add explicit logging to track what iOS sees vs what we provide

If that doesn't work, then Option C.

---

## What Not To Do

1. **Don't add more caches** - We have too many already
2. **Don't add more item types** - We have too many already
3. **Don't add more polling mechanisms** - One is enough
4. **Don't test on device without a theory** - We've done that, it didn't help

---

## Files to Reference

```bash
# Current state (stashed)
git stash show -p stash@{0}

# Blink's implementation (external)
# https://github.com/blinksh/blink/tree/main/BlinkFileProvider
```

---

## Update: The Real Question (Jan 5, 2026)

After writing all this analysis, the deeper question emerges:

**Why are we fighting File Provider so hard?**

File Provider is designed for cloud sync (Dropbox, iCloud, Google Drive). Those have:
- Push notifications for changes
- Conflict resolution protocols  
- Offline caching requirements

SFTP has:
- No push notifications (poll only)
- No built-in conflict resolution
- No offline requirement (it's a remote filesystem)

We're using File Provider because it's the *only* way to expose files to other iOS apps. But we're fighting against its design assumptions constantly.

### The Blink Insight

Blink made it work, but their File Provider is clearly a "bolt-on" feature, not their core architecture. Their terminal is the primary interface; File Provider is secondary.

### Our Vision Was Bigger

We wanted bidirectional File Provider access:
1. SFTP → Files.app (expose servers)
2. Files.app → Geistty (access other apps' files from terminal)

Direction 2 is actually cleaner - we're the *consumer* not the *provider*. We don't need polling, anchors, or change tracking to **read** from iCloud Drive.

### Maybe We Should...

1. Get Direction 1 barely working (browse only, no sync)
2. Build Direction 2 first (read from Files.app locations)
3. Return to Direction 1 sync features later

The "Syncing Paused" banner might just mean "I have nothing to sync" which is... true? We're a live SFTP browser, not a sync client.
