# SFTP → File Provider Architecture

**Date:** January 16, 2026  
**Purpose:** Understanding how SFTP sync maps to iOS File Provider, with lessons from rsync, Blink Shell, and Apple's sample code.

---

## The Core Problem

```
┌─────────────────┐                    ┌─────────────────┐
│   SFTP Server   │ ◄──── Network ────►│   iOS Device    │
│  (Source Truth) │                    │  (Local Cache)  │
└─────────────────┘                    └─────────────────┘
        │                                      │
        │                                      │
   No push events                         Files.app
   No change stream                       wants "sync"
   Stateless protocol                     wants "changes"
```

**SFTP is not a sync protocol.** It's a file transfer protocol. It has:
- No change notifications
- No revision history  
- No server-side anchors
- Only: list, read, write, delete

**File Provider expects sync semantics.** iOS wants:
- Anchors to track "where we left off"
- Change enumeration (what's new since anchor X?)
- Conflict detection (version mismatches)
- Two-way sync coordination

**This is the fundamental impedance mismatch we're solving.**

---

## rsync Philosophy (The Inspiration)

rsync is genius because it's brutally simple:

| Principle | rsync | Lesson for Us |
|-----------|-------|---------------|
| **One source of truth** | Source → Destination | SFTP server is source of truth |
| **Stateless** | No persistent sync state | Calculate delta fresh each time |
| **Checksums > timestamps** | Verify actual content | Don't trust cached metadata blindly |
| **Delta sync** | Only transfer differences | Only report changed items |

### rsync Algorithm (Simplified)

```
1. List source directory
2. List destination directory  
3. Compare (name + size + mtime)
4. For each difference:
   - Missing at dest? → Copy
   - Different content? → Update
   - Extra at dest? → Delete (if --delete)
5. Done. No state saved.
```

**Key insight:** rsync doesn't track "what changed since last run." It recalculates the diff every time. This is stateless and robust.

---

## iOS File Provider Contract

### What iOS Expects

```
                                iOS File Provider System
                                         │
              ┌──────────────────────────┼──────────────────────────┐
              │                          │                          │
              ▼                          ▼                          ▼
     ┌────────────────┐        ┌────────────────┐        ┌────────────────┐
     │  enumerator()  │        │ enumerateItems │        │enumerateChanges│
     │                │        │                │        │                │
     │ Returns object │        │ "What's in     │        │ "What changed  │
     │ for container  │        │  this folder?" │        │  since anchor?"|
     └────────────────┘        └────────────────┘        └────────────────┘
                                       │                          │
                                       ▼                          ▼
                                 observer.                  observer.
                                 didEnumerate([items])      didUpdate([items])
                                                           didDelete([ids])
                                                           finishEnumeratingChanges(
                                                             upTo: newAnchor)
```

### The Sync Anchor Contract

```swift
// iOS asks: "What's your current anchor?"
func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void)

// iOS says: "Tell me what changed since this anchor"
func enumerateChanges(for observer: NSFileProviderChangeObserver, 
                      from anchor: NSFileProviderSyncAnchor)
```

**Critical rules:**
1. Anchors must be **monotonically increasing** (or at least orderable)
2. `enumerateChanges` must return ALL changes since the given anchor
3. If anchor is too old (expired), return `NSFileProviderError.syncAnchorExpired`
4. The anchor you return from `finishEnumeratingChanges` becomes the "new baseline"

---

## How Blink Shell Does It

Blink is the reference implementation for SFTP → File Provider.

### Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                     FileProviderReplicatedExtension                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────┐     ┌─────────────────┐     ┌────────────────┐  │
│  │   WorkingSet    │◄───►│WorkingSetDatabase│◄───►│    SQLite     │  │
│  │   (Runtime)     │     │   (Persistence)  │     │   (Storage)   │  │
│  └────────┬────────┘     └─────────────────┘     └────────────────┘  │
│           │                                                          │
│           │ prepareChanges() ───────────────────────┐                │
│           │                                         ▼                │
│           │                              ┌─────────────────┐         │
│           │                              │ PollCoordinator │         │
│           │                              │ (Active Folders)│         │
│           │                              └────────┬────────┘         │
│           │                                       │                  │
│           ▼                                       ▼                  │
│  ┌─────────────────┐                   ┌─────────────────┐           │
│  │ WorkingSet      │                   │ FileProvider    │           │
│  │ Enumerator      │                   │ Replicated      │           │
│  │ (for .workingSet)                   │ Enumerator      │           │
│  └─────────────────┘                   │ (for folders)   │           │
│                                        └─────────────────┘           │
└──────────────────────────────────────────────────────────────────────┘
                    │                              │
                    │                              │
                    ▼                              ▼
           ┌─────────────────┐           ┌─────────────────┐
           │   SFTP Server   │◄─────────►│   SFTP Server   │
           │ (Working Set    │           │ (Folder Listing)│
           │  Polling)       │           │                 │
           └─────────────────┘           └─────────────────┘
```

### Blink's Key Patterns

#### 1. Anchor Format: `"VERSION-ITERATION"`

```swift
// Blink's anchor structure
var anchor: NSFileProviderSyncAnchor {
    NSFileProviderSyncAnchor("\(anchorVersion)-\(anchorIteration)".data(using: .utf8)!)
}

// Example: "ABCD-42"
// - "ABCD" = random version (changes on DB reset)
// - "42" = monotonic iteration counter
```

**Why version prefix?** If the database is reset, the iteration counter goes back to 0. The version ensures iOS knows the old anchor is invalid.

#### 2. Strict Anchor Validation

```swift
func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
    if anchor == self.anchor {
        // Same anchor = no changes
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        return
    } else if self.anchor.iteration == anchor.iteration + 1 {
        // Expected case: iOS has anchor N, we're at N+1
        // Return the changes
        observer.didUpdate(...)
        observer.didDeleteItems(...)
        observer.finishEnumeratingChanges(upTo: self.anchor, moreComing: false)
    } else {
        // Anchor mismatch - iOS has stale state
        observer.finishEnumeratingWithError(
            NSFileProviderError(.syncAnchorExpired)
        )
    }
}
```

**Critical:** Blink validates `anchor.iteration + 1 == currentAnchor.iteration`. If not, it fails with `syncAnchorExpired`.

#### 3. Commit Pattern

```swift
// Every write operation commits to WorkingSet
return self.workingSet.commitItemInSet(itemPath: itemPath) {
    // ... do the SFTP operation ...
    return createdItem
}
```

**This ensures:** Any item created/modified locally is immediately tracked in the database, so the next `enumerateChanges` will include it.

#### 4. Polling for Server Changes

```swift
func resumeChangesTimerEvery(seconds: Int) {
    let timer = DispatchSource.makeTimerSource()
    timer.setEventHandler { [weak self] in
        self?.prepareChangesAndSignalEnumerator()
    }
    timer.schedule(deadline: .now(), repeating: .seconds(seconds))
    timer.resume()
}
```

**prepareChanges() does:**
1. For each active folder enumerator:
   - Fetch fresh listing from SFTP
   - Compare against database (like rsync!)
   - Collect creates/updates/deletions
2. If changes found:
   - Increment anchor
   - Store changes
   - `signalEnumerator(for: .workingSet)`

#### 5. WorkingSet vs Folder Enumerators

| Enumerator Type | Purpose | Returns Anchor? |
|-----------------|---------|-----------------|
| `WorkingSetEnumerator` | Change tracking for iOS sync | **YES** |
| `FileProviderReplicatedEnumerator` | Folder browsing | **NO** (returns `nil`) |

**Only the WorkingSet participates in change tracking.** Folder enumerators just list contents.

---

## The Geistty Architecture (Current)

```
┌──────────────────────────────────────────────────────────────────────┐
│                     FileProviderExtension                            │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────┐     ┌─────────────────┐     ┌────────────────┐  │
│  │ MetadataStore   │◄───►│   SwiftData     │◄───►│   SQLite       │  │
│  │   (Actor)       │     │   (ORM)         │     │   (Storage)    │  │
│  └────────┬────────┘     └─────────────────┘     └────────────────┘  │
│           │                                                          │
│           │ changesSince(anchor) ─────────────────┐                  │
│           │                                       ▼                  │
│           │                             ┌─────────────────┐          │
│           │                             │ ActiveFolder    │          │
│           │                             │ Records         │          │
│           │                             └────────┬────────┘          │
│           │                                      │                   │
│           ▼                                      ▼                   │
│  ┌─────────────────┐                  ┌─────────────────┐            │
│  │ MetadataStore   │                  │ Remote          │            │
│  │ Enumerator      │                  │ Enumerator      │            │
│  │ (for .workingSet)                  │ (for folders)   │            │
│  └─────────────────┘                  └─────────────────┘            │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
                    │                              │
                    │                              │
                    ▼                              ▼
           ┌─────────────────┐           ┌─────────────────┐
           │   MetadataStore │           │   SFTP Server   │
           │   (Polling?)    │           │ (Folder Listing)│
           └─────────────────┘           └─────────────────┘
```

### Current Flow

1. **Browse folder** → `RemoteEnumerator.enumerateItems()` → SFTP list → `MetadataStore.upsertBatch()`
2. **Create/Modify/Delete** → SFTP operation → `MetadataStore.upsert()` → `signalEnumerator(.workingSet)`
3. **iOS asks for changes** → `MetadataStoreEnumerator.enumerateChanges()` → Query SwiftData

### Current Problems

| Issue | Description |
|-------|-------------|
| **No polling** | Server-side changes aren't detected until user browses |
| **Anchor format** | `UInt64` only - no version prefix for DB resets |
| **Permissive validation** | Accepts any older anchor (should be stricter?) |
| **Domain state caching** | iOS caches "Syncing Paused" even after code fixes |

---

## rsync-Inspired Redesign

What if we simplified radically, taking rsync's stateless approach?

### The Idea

```
iOS calls enumerateChanges(from: anchor)
         │
         ▼
    ┌────────────────────────────────────┐
    │ Ignore anchor value entirely.      │
    │ Just record that iOS called us.    │
    └────────────────────────────────────┘
         │
         ▼
    ┌────────────────────────────────────┐
    │ For each "active" folder:          │
    │   1. Fetch fresh from SFTP         │
    │   2. Diff against local cache      │
    │   3. Collect changes               │
    └────────────────────────────────────┘
         │
         ▼
    ┌────────────────────────────────────┐
    │ Report ALL collected changes       │
    │ Return anchor = Date.now or        │
    │                  incrementing int  │
    └────────────────────────────────────┘
```

### Key Simplifications

1. **Server is always source of truth** - we never "remember" changes, we recalculate them
2. **Anchor is just a timestamp** - "last time we synced"
3. **No anchor validation** - any anchor triggers a full diff
4. **Staleness = time-based** - if cache is > 5 min old, refresh on next access

### Pseudocode

```swift
func enumerateChanges(for observer: NSFileProviderChangeObserver, 
                      from anchor: NSFileProviderSyncAnchor) {
    Task {
        var allChanges: [Change] = []
        
        // Refresh all active folders (like rsync -r)
        for folder in activeFolders {
            let serverItems = try await sftp.list(folder.path)
            let cachedItems = cache.items(in: folder)
            
            // Diff (rsync-style)
            let diff = calculateDiff(server: serverItems, cache: cachedItems)
            allChanges.append(contentsOf: diff)
            
            // Update cache
            cache.replace(folder: folder, with: serverItems)
        }
        
        // Report to iOS
        for change in allChanges {
            switch change {
            case .added(let item), .modified(let item):
                observer.didUpdate([item])
            case .deleted(let id):
                observer.didDeleteItems(withIdentifiers: [id])
            }
        }
        
        // Anchor = "we just synced"
        let newAnchor = makeAnchor(Date())
        observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
    }
}
```

### Trade-offs

| Aspect | Current Approach | rsync-Style |
|--------|------------------|-------------|
| **Complexity** | High (anchor tracking, validation) | Low (just diff) |
| **Network usage** | Only when signaled | Every enumerateChanges |
| **Stale data risk** | High (if anchor desync) | Low (always fresh) |
| **Offline support** | Better (cache-based) | Worse (needs server) |
| **Scalability** | Better for large trees | Worse (must diff all) |

---

## Apple's Sample Code Patterns

From Apple's FruitBasket sample:

### 1. Server as Source of Truth

```swift
// The extensions don't maintain a local copy of the working set. 
// When the system requests items, the extensions make a JSON call 
// to retrieve the relevant information from the server, and pass 
// the result to the system.
```

### 2. Signal-Based Change Detection

```swift
// Two ways to notify file provider extensions of server changes:
// 1. PushKit notifications (fileprovider push type)
// 2. App calls signalEnumerator() after detecting changes
```

### 3. Resolvable Errors

```swift
// Four resolvable errors:
// - .notAuthenticated
// - .serverUnreachable  
// - .insufficientQuota
// - .cannotSynchronize

// When encountered, system throttles operations until:
signalErrorResolved(.notAuthenticated)
```

---

## Recommended Architecture for Geistty

Based on all of the above, here's the recommended direction:

### Phase 1: Fix Current Issues

1. **Add anchor version prefix** - Detect DB resets
   ```swift
   // Anchor format: "V1-42" (version-iteration)
   let anchor = "\(dbVersion)-\(iteration)"
   ```

2. **Add polling** - Like Blink's timer-based polling
   ```swift
   // Every 5-10 seconds, check active folders
   timer.schedule(repeating: .seconds(5))
   ```

3. **Validate anchors strictly** - Match Blink's pattern
   ```swift
   if anchor.iteration + 1 != current.iteration {
       return .syncAnchorExpired
   }
   ```

### Phase 2: rsync-Style Simplification (Optional)

If Phase 1 doesn't resolve "Syncing Paused":

1. **Make `enumerateChanges` always diff** - Don't rely on stored change history
2. **Simplify anchor to timestamp** - Just track "last sync time"
3. **Remove complex change tracking** - Let the diff be the source of truth

### Phase 3: Robust Offline Support

1. **Cache validation** - Track cache freshness per folder
2. **Conflict detection** - Compare versions on upload
3. **Retry queue** - For failed operations

---

## Data Flow Diagrams

### User Browses Folder

```
User taps folder in Files.app
         │
         ▼
iOS calls enumerator(for: folderID)
         │
         ▼
We return RemoteEnumerator(folderID)
         │
         ▼
iOS calls enumerateItems(for: observer)
         │
         ▼
RemoteEnumerator:
  1. SFTP list(folder)
  2. MetadataStore.upsertBatch(items)
  3. observer.didEnumerate(items)
  4. signalEnumerator(.workingSet) if changes
         │
         ▼
iOS displays folder contents
```

### iOS Syncs Working Set

```
iOS decides to sync (periodic or triggered)
         │
         ▼
iOS calls enumerator(for: .workingSet)
         │
         ▼
We return MetadataStoreEnumerator()
         │
         ▼
iOS calls currentSyncAnchor(completion)
         │
         ▼
We return current anchor (e.g., 42)
         │
         ▼
iOS calls enumerateChanges(from: anchor 40)
         │
         ▼
MetadataStoreEnumerator:
  1. Query MetadataStore for items where modifiedAtAnchor > 40
  2. Query for deletions since anchor 40
  3. observer.didUpdate(modifiedItems)
  4. observer.didDeleteItems(deletedIDs)
  5. observer.finishEnumeratingChanges(upTo: 42)
         │
         ▼
iOS updates its internal state
```

### User Creates File

```
User creates file in Files.app
         │
         ▼
iOS calls createItem(basedOn: template, contents: URL)
         │
         ▼
FileProviderExtension:
  1. SFTP write(contents, to: remotePath)
  2. SFTP stat(remotePath) → get server metadata
  3. MetadataStore.upsert(item)  ← Commits to DB, increments anchor
  4. completionHandler(createdItem)
  5. signalEnumerator(.workingSet)  ← Tells iOS changes available
         │
         ▼
iOS calls enumerateChanges to pick up the new item
```

---

## Key Takeaways

1. **SFTP has no change stream** - We must poll or diff to detect server changes
2. **Anchors must be monotonic** - And validated strictly
3. **Commit every write** - Local operations must immediately update the database
4. **Server is source of truth** - Cache is just for performance/offline
5. **Signal after every change** - `signalEnumerator(.workingSet)` is critical
6. **rsync teaches simplicity** - When in doubt, recalculate the diff

---

## References

- [Apple: Synchronizing files using file provider extensions](https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions)
- [Apple: NSFileProviderReplicatedExtension](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension)
- [Blink Shell File Provider](https://github.com/blinksh/blink/tree/main/BlinkFileProvider)
- [rsync algorithm](https://rsync.samba.org/tech_report/)
- [WWDC 2021: Sync files to the cloud with FileProvider on macOS](https://developer.apple.com/videos/play/wwdc2021/10182/)
