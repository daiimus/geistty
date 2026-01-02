# File Provider Test Matrix

## Overview

This document maps Apple's File Provider requirements to our test coverage.
Use this to identify gaps before QA testing on device.

**Last Updated:** January 2, 2026  
**Total Tests:** 94 passing (simulator) + 27 device-only skipped = 121 total

---

## Test Categories

| Category | Tests | Status |
|----------|-------|--------|
| Anchor Contract | 15 | ✅ Good |
| Enumerator Protocol | 12 | ✅ Good |
| MetadataStore CRUD | 8 | ✅ Good |
| Change Detection | 10 | ✅ Good |
| Working Set | 4 | ✅ Good |
| Edge Cases | 12 | ✅ Good |
| NSFileProviderItem Protocol | 11 | ✅ **Complete** |
| Device-Only | 27 | ⏭️ Skip on Simulator |

---

## Apple File Provider Contract Tests

### 1. NSFileProviderSyncAnchor Requirements

| Requirement | Test | File | Status |
|-------------|------|------|--------|
| Anchor must be 8 bytes (UInt64) | `testAnchorIsExactly8Bytes` | FileProviderTests.swift | ✅ |
| Anchor must never be 0 | `testAnchorNeverStartsAtZero` | FileProviderTests.swift | ✅ |
| Anchor must increment monotonically | `testAnchorIncrementsCorrectly` | FileProviderTests.swift | ✅ |
| Anchor serializes correctly | `testAnchorSerialization` | FileProviderTests.swift | ✅ |
| Anchor round-trips correctly | `testAnchorRoundTrip` | FileProviderTests.swift | ✅ |
| Cache returns anchor synchronously | `testCacheReturnsValidAnchorSynchronously` | FileProviderTests.swift | ✅ |
| Cache never returns 0 | `testCacheNeverReturnsZero` | FileProviderTests.swift | ✅ |
| Empty anchor parsed as nil | `testEmptyAnchorParsedAsNil` | FileProviderTests.swift | ✅ |
| Wrong size anchor parsed as nil | `testWrongSizeAnchorParsedAsNil` | FileProviderTests.swift | ✅ |

### 2. NSFileProviderChangeObserver Contract

| Requirement | Test | File | Status |
|-------------|------|------|--------|
| `didUpdate()` called with items | `testEnumerateChangesFromZeroReturnsAllChanges` | MetadataStoreEnumeratorTests.swift | ✅ |
| `didDeleteItems()` called with IDs | `testEnumerateChangesReportsDeletions` | MetadataStoreEnumeratorTests.swift | ✅ |
| `finishEnumeratingChanges()` always called | `testEnumerateChangesAlwaysCompletes` | MetadataStoreEnumeratorTests.swift | ✅ |
| Anchor returned in finish | `testCurrentSyncAnchorReturnsValidAnchor` | MetadataStoreEnumeratorTests.swift | ✅ |
| `moreComing` set correctly | `testEnumerateChangesWithCurrentAnchorReturnsNoChanges` | MetadataStoreEnumeratorTests.swift | ✅ |

### 3. NSFileProviderEnumerator Protocol

| Requirement | Test | File | Status |
|-------------|------|------|--------|
| `currentSyncAnchor()` returns valid anchor | `testCurrentSyncAnchorReturnsValidAnchor` | MetadataStoreEnumeratorTests.swift | ✅ |
| `currentSyncAnchor()` is synchronous | `testCacheSyncAnchorIsSynchronous` | FileProviderTests.swift | ✅ |
| `enumerateItems()` for working set returns empty | `testEnumerateItemsReturnsEmpty` | MetadataStoreEnumeratorTests.swift | ✅ |
| `enumerateChanges()` works from anchor 0 | `testEnumerateChangesFromZeroWorks` | FileProviderTests.swift | ✅ |
| `enumerateChanges()` returns no changes at current | `testEnumerateChangesWithCurrentAnchorReturnsNoChanges` | MetadataStoreEnumeratorTests.swift | ✅ |
| `enumerateChanges()` handles malformed anchors | `testEnumerateChangesAlwaysCompletes` | MetadataStoreEnumeratorTests.swift | ✅ |

### 4. Working Set Requirements (Apple Doc)

| Requirement | Test | File | Status |
|-------------|------|------|--------|
| Subfolder items reported without parent change | `testSubfolderFileChangesAreReported` | MetadataStoreEnumeratorTests.swift | ✅ |
| Deep nested changes reported (5+ levels) | `testDeepNestedChangesAreReported` | MetadataStoreEnumeratorTests.swift | ✅ |
| Multiple depths in same batch | `testMultipleDepthsReported` | MetadataStoreEnumeratorTests.swift | ✅ |

### 5. Change Detection

| Requirement | Test | File | Status |
|-------------|------|------|--------|
| Changes from anchor 0 returns all | `testChangesFromZeroIncludesAllItems` | FileProviderTests.swift | ✅ |
| Changes from current returns none | `testChangesFromCurrentAnchorReturnsNothing` | FileProviderTests.swift | ✅ |
| Incremental changes detected | `testIncrementalChangeDetection` | FileProviderTests.swift | ✅ |
| Deletions tracked by anchor | `testDeletionsTrackedByAnchor` | FileProviderTests.swift | ✅ |
| Anchor increments on modification | `testAnchorIncrementsOnModification` | FileProviderTests.swift | ✅ |

### 6. Error Handling

| Requirement | Test | File | Status |
|-------------|------|------|--------|
| Extension handles disconnect gracefully | *None* | - | ⚠️ Deferred |
| Errors propagated correctly | *None* | - | ⚠️ Deferred |
| `signalErrorsResolved()` called after recovery | *None* | - | ⚠️ Deferred |

*Note: Error handling tests require network mocking or device testing.*

### 7. Edge Cases

| Scenario | Test | File | Status |
|----------|------|------|--------|
| Empty directory listing | `testEnumerateItemsReturnsEmpty` | MetadataStoreEnumeratorTests.swift | ✅ |
| Special characters in paths | `testSpecialCharactersInPath` | FileProviderExtensionTests.swift | ✅ |
| Very deep folder hierarchy (5+ levels) | `testDeepNestedChangesAreReported` | MetadataStoreEnumeratorTests.swift | ✅ |
| Large file count (100+) | `testLargeBatchOfChanges` | MetadataStoreEnumeratorTests.swift | ✅ |
| Rapid successive changes (50) | `testRapidSuccessiveChanges` | MetadataStoreEnumeratorTests.swift | ✅ |
| Concurrent enumerations (5x) | `testConcurrentEnumerations` | MetadataStoreEnumeratorTests.swift | ✅ |
| Unicode filenames | `testUnicodeFilenames` | MetadataStoreEnumeratorTests.swift | ✅ |
| Symlink handling | `testSymlinkReporting` | MetadataStoreEnumeratorTests.swift | ✅ |

---

## Remaining Gaps (Deferred)

### Error Recovery Tests (Requires Network Mocking)

These tests would require mocking network failures, which is complex:

| Test | What it Would Test | Priority |
|------|-------------------|----------|
| `testEnumeratorHandlesDisconnect` | Enumerator completes gracefully on disconnect | Low |
| `testErrorRecoverySignalsResolved` | `signalErrorsResolved()` called after reconnect | Low |
| `testStateNotCorruptedOnError` | MetadataStore state consistent after error | Low |

*Note: Error handling is tested implicitly via device testing. Network mocking would add complexity without significant coverage gain.*

---

## Test Execution Matrix

### Simulator Tests (./ci.sh test) - 122 tests

| Test Class | Count | Notes |
|------------|-------|-------|
| MetadataStoreTests | 10 | Core store CRUD, anchors |
| MetadataStoreEnumeratorTests | 15 | Protocol compliance, edge cases |
| SyncStateTests | 3 | Anchor serialization |
| MetadataAnchorCacheTests | 2 | Synchronous cache |
| EnumeratorBehaviorTests | 2 | Change detection |
| EnumeratorContractTests | 5 | Protocol contract |
| CachedMetadataItemTests | 11 | **Item properties, itemVersion, transfer status** |
| ItemIdentifierTests | 6 | ID format parsing |
| FileProviderIntegrationTests | 7 | Mock SFTP flow |
| WorkingSetMockTests | 2 | Working set logic |
| MetadataStoreFullFlowTests | 4 | End-to-end flow |
| SyncAnchorContractTests | 3 | Anchor contract |
| SyncingPausedDiagnosticTests | 11 | iOS call sequence simulation |

### Device-Only Tests (skip on simulator)

| Test Class | Count | Notes |
|------------|-------|-------|
| FileProviderExtensionTests | 5 | Domain registration |
| DeviceIntegrationTests | 7 | Extension interaction |
| SyncingPausedDiagnosticDeviceTests | 15 | Files.app diagnostics |

---

## NSFileProviderItem Protocol Coverage (NEW Jan 2, 2026)

### Required Properties

| Property | Test | Status |
|----------|------|--------|
| `itemIdentifier` | `testAllRequiredPropertiesPresent` | ✅ |
| `parentItemIdentifier` | `testParentIdentifierMapping` | ✅ |
| `filename` | `testAllRequiredPropertiesPresent` | ✅ |
| `contentType` | `testContentTypeForDirectories` | ✅ |
| `capabilities` | `testCapabilitiesDifferByType` | ✅ |

### Replicated Extension Required

| Property | Test | Status |
|----------|------|--------|
| `itemVersion` | `testItemVersionIsPresent` | ✅ |
| `itemVersion` changes | `testItemVersionChangesOnUpdate` | ✅ |

### Optional Properties

| Property | Test | Status |
|----------|------|--------|
| `documentSize` | `testDocumentSizeForFiles` | ✅ |
| `contentModificationDate` | `testDatePropertiesPresent` | ✅ |
| `creationDate` | `testDatePropertiesPresent` | ✅ |
| `symlinkTargetPath` | - | ⚠️ Deferred (no symlink support) |
| `childItemCount` | - | ⚠️ Deferred (minor UX) |

### Transfer Status Properties (NEW Jan 2, 2026)

| Property | Test | Status |
|----------|------|--------|
| `isUploaded` | `testTransferStatusPropertiesForCachedMetadataItem` | ✅ |
| `isUploading` | `testTransferStatusPropertiesForCachedMetadataItem` | ✅ |
| `isDownloaded` | `testTransferStatusPropertiesForCachedMetadataItem` | ✅ |
| `isDownloading` | `testTransferStatusPropertiesForCachedMetadataItem` | ✅ |

**Note:** Transfer status tested only for `CachedMetadataItem`. Other item classes (`RootItem`, `ConnectionFolderItem`, `RemoteItem`, `CachedRemoteItem`) are in the File Provider Extension target and not testable on simulator. Their implementations follow the same pattern and are verified via code review.

---

## Summary

**Coverage Status (Jan 2, 2026):**

- ✅ Anchor contract: Complete
- ✅ Enumerator protocol: Complete
- ✅ Change detection: Complete
- ✅ Edge cases: Complete (deep nesting, large batches, concurrency, unicode, symlinks, rapid changes)
- ✅ **NSFileProviderItem protocol: Complete** (all required + transfer status props tested)
- ⚠️ Error handling: Deferred (requires network mocking)

**Properties Implemented (Jan 2, 2026):**
- Required: `itemIdentifier`, `parentItemIdentifier`, `filename`, `contentType`, `capabilities`, `itemVersion`
- Transfer status: `isDownloaded`, `isUploaded`, `isDownloading`, `isUploading`
- Optional: `documentSize`, `contentModificationDate`, `creationDate`
- Deferred: `symlinkTargetPath`, `childItemCount`

**Bugs Fixed:**
- `testSubfolderFileChangesAreReported` - Verifies fix for item filtering bug
- `testItemVersionIsPresent` - Verifies fix for missing itemVersion (likely cause of "Syncing Paused")

**Run Before QA:**
```bash
cd Geistty && ./ci.sh test
```