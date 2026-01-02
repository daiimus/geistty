# Geistty Codebase Audit

**Date**: January 2, 2026  
**Status**: In Progress

This document tracks technical debt identified during comprehensive code review.

---

## Summary of Findings

| Category | Issues Found | Priority | Status |
|----------|-------------|----------|--------|
| File Provider (Phase 1) | 615 lines dead code | HIGH | ✅ DONE |
| File Provider (Phase 2) | 4 duplicate debugLog, 5 NSFileProviderItem classes | MEDIUM | 🔄 In Progress |
| Logging Inconsistency | Mixed Logger + NSLog + debugLog | MEDIUM | Not Started |
| TODOs in Code | 4 legitimate TODOs | LOW | Documented |
| SSH/Terminal | Minor | LOW | Not Started |

---

## File Provider Technical Debt

### Phase 1 - Dead Code (COMPLETED Jan 2, 2026)

| File | Status | Lines Removed |
|------|--------|---------------|
| `WorkingSet.swift` | ✅ DELETED | 542 |
| `SimpleWorkingSetEnumerator.swift` | ✅ DELETED | 73 |
| **Total** | | **615** |

**Details**: See `FILE_PROVIDER_CODE_AUDIT.md` for full analysis.

### Phase 2 - Consolidation (IN PROGRESS)

#### 2.1 Duplicate `debugLog()` Functions

**File**: `FileProviderExtension.swift`

4 identical private functions in different classes:

| Class | Line | Log Prefix |
|-------|------|------------|
| `SFTPConnectionManager` | 79 | "SFTPConnectionManager:" |
| `FileProviderExtension` | 365 | (none) |
| `ConnectionsEnumerator` | 1167 | "ConnectionsEnumerator:" |
| `RemoteEnumerator` | 1393 | "RemoteEnumerator:" |

**Solution**: Extract to top-level utility function with category parameter.

#### 2.2 NSFileProviderItem Implementations

5 separate classes implementing `NSFileProviderItem`:

| Class | Location | Purpose |
|-------|----------|---------|
| `RootItem` | FileProviderExtension.swift:997 | Root container |
| `ConnectionFolderItem` | FileProviderExtension.swift:1020 | Connection folder |
| `RemoteItem` | FileProviderExtension.swift:1051 | Live SFTP item |
| `CachedRemoteItem` | FileProviderExtension.swift:1434 | SwiftData CachedItem |
| `CachedMetadataItem` | MetadataStoreEnumerator.swift:142 | CachedFileMetadata |

**Issue**: `CachedRemoteItem` and `CachedMetadataItem` serve similar purposes with slightly different backing stores.

**Recommendation**: Keep both for now - they use different SwiftData models (`CachedItem` vs `CachedFileMetadata`). The duplication is intentional as we migrate from one caching strategy to another.

#### 2.3 Item Identifier Helpers

Two parallel implementations:

| Location | Format |
|----------|--------|
| `MetadataStore.swift` - `ItemIdentifier` enum | Static functions |
| `CachedFileMetadata.swift` - extension | Static functions |

**Recommendation**: Consolidate into `ItemIdentifier` enum; add deprecation warnings to `CachedFileMetadata` extensions.

---

## Logging Inconsistency

### Current State

The codebase uses THREE different logging approaches:

| Method | Count | Files |
|--------|-------|-------|
| `Logger` (os.log) | 21+ | Most production code |
| `NSLog` | 40+ | FileProviderExtension, MetadataStore |
| `debugLog()` | 4 | FileProviderExtension nested classes |

### Logger Subsystems

| Subsystem | Usage |
|-----------|-------|
| `com.geistty` | Main app (13 files) |
| `com.geistty.fileprovider` | File Provider extension (3 files) |
| `com.geistty.app` | TmuxSplitTree only (inconsistent) |

**Issue**: `TmuxSplitTree.swift` uses `com.geistty.app` while all other files use `com.geistty`.

### Recommendation

1. Remove `debugLog()` file-based logging (replace with Logger)
2. Standardize on Logger with consistent subsystems
3. Use `NSLog` only where `Logger` isn't available (e.g., very early startup)

---

## TODOs in Geistty Code

| File | Line | TODO |
|------|------|------|
| `Ghostty.swift` | 115 | "Read from actual config once we parse it" |
| `MetadataStore.swift` | 621 | "Track actual item updates (size/date changes)" |
| `SSHSession.swift` | 440 | "Implement decryption for aes256-ctr, aes256-cbc, etc." |
| `TerminalContainerView.swift` | 1046 | "Implement via Ghostty API if available" |

**Note**: `FontMapping.swift` matches "hack" due to the "Hack" font name, not a TODO.

---

## SSH/Terminal Code Review

### Files Reviewed

| Directory | Files | Status |
|-----------|-------|--------|
| `Sources/SSH/` | 9 files | Minor issues |
| `Sources/Terminal/` | 5 files | Clean |
| `Sources/SFTP/` | 8 files | Clean |

### Minor Issues

1. **TmuxLayout.swift** - Note about old implementation moved to new file (line 65)
2. **TmuxModels.swift** - Note about TmuxLayout being moved (line 133)

No dead code found in SSH/Terminal directories.

---

## Cleanup Action Plan

### Immediate (Phase 2)

- [x] Document all findings
- [ ] Create shared `FileProviderDebugLog` utility
- [ ] Replace 4 duplicate `debugLog()` functions
- [ ] Fix `TmuxSplitTree.swift` subsystem (`com.geistty.app` → `com.geistty`)

### Deferred (Lower Priority)

- [ ] Consolidate `ItemIdentifier` helpers
- [ ] Migrate `NSLog` → `Logger` where appropriate
- [ ] Address TODOs (feature work, not cleanup)

---

## Change Log

| Date | Action | Lines Affected |
|------|--------|----------------|
| 2026-01-02 | Phase 1 cleanup (WorkingSet, SimpleWorkingSetEnumerator) | -615 |
| 2026-01-02 | Created CODEBASE_AUDIT.md | - |

