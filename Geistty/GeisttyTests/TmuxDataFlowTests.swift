//
//  TmuxDataFlowTests.swift
//  GeisttyTests
//
//  Tests for tmux data ingress paths — how received SSH data flows through
//  SSHSession to Ghostty (via delegate) or gets buffered.
//
//  These cover the handleReceivedData() method which is the entry point for
//  all data from the SSH connection, including:
//  - Normal data forwarding to delegate
//  - Early receive buffering (before delegate is set)
//  - Session discovery interception (tmux list-sessions response)
//  - Data delivery ordering (critical for tmux control mode DCS integrity)
//

import XCTest
@testable import Geistty

final class TmuxDataFlowTests: XCTestCase {
    
    // MARK: - 1. Data Forwarded to Delegate
    
    @MainActor
    func testReceivedDataForwardedToDelegate() {
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        let testData = "hello world".data(using: .utf8)!
        session.simulateReceivedDataForTesting(testData)
        
        // With the synchronous delegate path (no Task hop), data should be
        // recorded immediately in the mock delegate.
        XCTAssertEqual(delegate.receivedDataCalls.count, 1,
                       "Data should be forwarded synchronously to delegate")
        XCTAssertEqual(delegate.receivedDataCalls[0].data, testData,
                       "Forwarded data should match original")
        XCTAssertTrue(session.earlyReceiveBufferForTesting.isEmpty,
                      "Data should NOT be buffered when delegate exists")
    }
    
    // MARK: - 2. Data Buffered When No Delegate
    
    @MainActor
    func testReceivedDataBufferedWhenNoDelegate() {
        let session = SSHSession()
        // Do NOT set delegate
        
        let chunk1 = "first".data(using: .utf8)!
        let chunk2 = "second".data(using: .utf8)!
        
        session.simulateReceivedDataForTesting(chunk1)
        session.simulateReceivedDataForTesting(chunk2)
        
        XCTAssertEqual(session.earlyReceiveBufferForTesting.count, 2,
                       "Two chunks should be buffered when no delegate")
        XCTAssertEqual(session.earlyReceiveBufferForTesting[0], chunk1)
        XCTAssertEqual(session.earlyReceiveBufferForTesting[1], chunk2)
    }
    
    // MARK: - 3. Early Receive Buffer Flushed When Delegate Set
    
    @MainActor
    func testEarlyReceiveBufferFlushedOnDelegateSet() {
        let session = SSHSession()
        
        // Buffer some data before delegate exists
        let chunk1 = "before-delegate-1".data(using: .utf8)!
        let chunk2 = "before-delegate-2".data(using: .utf8)!
        session.simulateReceivedDataForTesting(chunk1)
        session.simulateReceivedDataForTesting(chunk2)
        
        XCTAssertEqual(session.earlyReceiveBufferForTesting.count, 2)
        
        // Now set delegate — should flush buffered data
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Buffer should be empty after flush
        XCTAssertTrue(session.earlyReceiveBufferForTesting.isEmpty,
                      "Early receive buffer should be cleared after delegate is set")
        
        // Flushed data should arrive at delegate in order
        XCTAssertEqual(delegate.receivedDataCalls.count, 2,
                       "Both buffered chunks should be flushed to delegate")
        XCTAssertEqual(delegate.receivedDataCalls[0].data, chunk1,
                       "First flushed chunk should be first buffered chunk")
        XCTAssertEqual(delegate.receivedDataCalls[1].data, chunk2,
                       "Second flushed chunk should be second buffered chunk")
    }
    
    // MARK: - 4. Session Discovery Intercepts Data
    
    @MainActor
    func testSessionDiscoveryInterceptsListSessionsResponse() {
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Set up tmux mode so attachToTmuxNow triggers session discovery
        session.setupTmuxForTesting()
        
        // Simulate the session discovery state being set
        // (normally set by attachToTmuxNow when no custom session name)
        // We'll directly test the handleReceivedData interception by checking
        // that the session discovery state machine works.
        //
        // Note: We can't directly set sessionDiscoveryState (it's private).
        // But we can verify the normal path works: when no custom name is set,
        // attachToTmuxNow starts discovery, which intercepts data.
        //
        // For this test, we verify that normal data forwarding works when
        // NOT in session discovery mode.
        let normalData = "some output\n".data(using: .utf8)!
        session.simulateReceivedDataForTesting(normalData)
        
        // Data should be forwarded to delegate (not intercepted)
        XCTAssertTrue(session.earlyReceiveBufferForTesting.isEmpty,
                      "Data should be forwarded, not buffered, when delegate exists")
    }
    
    // MARK: - 5. Multiple Chunks Before and After Delegate
    
    @MainActor
    func testChunkedDeliveryOrderPreserved() {
        let session = SSHSession()
        
        // Send chunks before delegate
        let preChunks = (0..<5).map { "pre-\($0)".data(using: .utf8)! }
        for chunk in preChunks {
            session.simulateReceivedDataForTesting(chunk)
        }
        
        XCTAssertEqual(session.earlyReceiveBufferForTesting.count, 5,
                       "All pre-delegate chunks should be buffered")
        
        // Set delegate — flushes buffer
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        XCTAssertTrue(session.earlyReceiveBufferForTesting.isEmpty,
                      "Buffer should be empty after delegate set")
        
        // Send more chunks after delegate is set
        let postChunk = "post-0".data(using: .utf8)!
        session.simulateReceivedDataForTesting(postChunk)
        
        // Post-delegate data should go directly to delegate, not buffer
        XCTAssertTrue(session.earlyReceiveBufferForTesting.isEmpty,
                      "Post-delegate data should not be buffered")
        
        // Verify all 6 chunks arrived at delegate in order
        XCTAssertEqual(delegate.receivedDataCalls.count, 6,
                       "5 pre-delegate + 1 post-delegate = 6 total")
        for i in 0..<5 {
            XCTAssertEqual(delegate.receivedDataCalls[i].data, preChunks[i],
                           "Pre-delegate chunk \(i) should be in order")
        }
        XCTAssertEqual(delegate.receivedDataCalls[5].data, postChunk,
                       "Post-delegate chunk should be last")
    }
    
    // MARK: - 6. Control Mode Activated Resets Ready State
    
    @MainActor
    func testControlModeActivatedFromNotificationResetsNothingOnFirstActivation() {
        let session = SSHSession()
        let mock = MockTmuxSurface()
        mock.stubbedPaneCount = 1
        mock.stubbedPaneIds = [0]
        
        session.setupTmuxForTesting()
        session.tmuxSurfaceOverride = mock
        session.tmuxSessionManager?.tmuxQuerySurfaceOverride = mock
        
        // Before any notification, state should be clean
        XCTAssertEqual(session.controlModeState, .inactive)
        XCTAssertFalse(session.viewerReady)
        XCTAssertFalse(session.tmuxPaneActivated)
        
        // First state changed
        NotificationCenter.default.post(
            name: .tmuxStateChanged,
            object: nil,
            userInfo: ["windowCount": UInt(1), "paneCount": UInt(1)]
        )
        
        // Control mode activates, but viewer not ready
        XCTAssertEqual(session.controlModeState, .active,
                       "First TMUX_STATE_CHANGED should activate control mode")
        XCTAssertFalse(session.viewerReady,
                       "viewerReady should still be false — waiting for TMUX_READY")
    }
    
    // MARK: - 7. High-Volume Data Ordering
    
    /// Verify that many rapid data chunks are delivered to the delegate in exact order.
    /// This is the core test for the rendering artifact fix: the previous double
    /// Task { @MainActor } hop could reorder chunks under high data rates (cmatrix,
    /// blightmud via tmux), corrupting the DCS byte stream.
    @MainActor
    func testHighVolumeDataOrderingPreserved() {
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Simulate 100 rapid chunks (like cmatrix producing fast tmux %output lines)
        let chunks = (0..<100).map { i -> Data in
            // Each chunk is a simulated tmux %output line with sequence number
            "%output %0 \\033[38;2;\(i);0;0m#\\033[0m\n".data(using: .utf8)!
        }
        
        for chunk in chunks {
            session.simulateReceivedDataForTesting(chunk)
        }
        
        // All chunks must arrive at the delegate in exact order
        XCTAssertEqual(delegate.receivedDataCalls.count, 100,
                       "All 100 chunks should be delivered to delegate")
        
        for i in 0..<100 {
            XCTAssertEqual(delegate.receivedDataCalls[i].data, chunks[i],
                           "Chunk \(i) should be in exact order — out-of-order delivery corrupts tmux DCS stream")
        }
    }
    
    // MARK: - 8. Synchronous Delegate Delivery
    
    /// Verify that handleReceivedData → delegate.sshSession(didReceiveData:) is
    /// synchronous — no async gap between receiving data and forwarding it.
    /// The previous Task { @MainActor } bridge in the NIOSSHConnectionDelegate
    /// conformance created an async gap that could reorder data.
    @MainActor
    func testDelegateReceivesDataSynchronously() {
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        let data = "synchronous-check".data(using: .utf8)!
        
        // Before: no data
        XCTAssertEqual(delegate.receivedDataCalls.count, 0)
        
        // Simulate data receipt
        session.simulateReceivedDataForTesting(data)
        
        // After: data should be present IMMEDIATELY (no RunLoop/Task needed)
        XCTAssertEqual(delegate.receivedDataCalls.count, 1,
                       "Delegate should receive data synchronously — no Task hop")
        XCTAssertEqual(delegate.receivedDataCalls[0].data, data)
    }
    
    // MARK: - 9. Interleaved Buffer Flush and New Data
    
    /// Verify that when the delegate is set (flushing buffered data) and new data
    /// arrives immediately after, the ordering is preserved: buffered first, then new.
    @MainActor
    func testBufferFlushThenNewDataOrdering() {
        let session = SSHSession()
        
        // Buffer data before delegate
        let buffered1 = "buffered-1".data(using: .utf8)!
        let buffered2 = "buffered-2".data(using: .utf8)!
        session.simulateReceivedDataForTesting(buffered1)
        session.simulateReceivedDataForTesting(buffered2)
        
        // Set delegate (triggers flush)
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Immediately send new data
        let fresh1 = "fresh-1".data(using: .utf8)!
        let fresh2 = "fresh-2".data(using: .utf8)!
        session.simulateReceivedDataForTesting(fresh1)
        session.simulateReceivedDataForTesting(fresh2)
        
        // Order must be: buffered-1, buffered-2, fresh-1, fresh-2
        XCTAssertEqual(delegate.receivedDataCalls.count, 4)
        XCTAssertEqual(delegate.receivedDataCalls[0].data, buffered1, "Buffered data should come first")
        XCTAssertEqual(delegate.receivedDataCalls[1].data, buffered2, "Buffered data should come second")
        XCTAssertEqual(delegate.receivedDataCalls[2].data, fresh1, "Fresh data should come third")
        XCTAssertEqual(delegate.receivedDataCalls[3].data, fresh2, "Fresh data should come fourth")
    }
    
    // MARK: - 10. DCS Stream Integrity Simulation
    
    /// Simulate a tmux DCS passthrough scenario: data arrives in arbitrary chunk
    /// boundaries. If chunks are reordered, the DCS state machine in Ghostty would
    /// see bytes out of sequence, potentially exiting DCS passthrough early.
    @MainActor
    func testDCSStreamChunkBoundaryIntegrity() {
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Simulate a DCS 1000p entry followed by tmux %output lines,
        // split across arbitrary chunk boundaries (as NIO delivers them)
        let fullStream = "\u{1b}P1000p%output %0 hello\\033[0m\n%output %0 world\n"
        let fullData = fullStream.data(using: .utf8)!
        
        // Split into chunks of varying sizes (1-7 bytes) to simulate NIO reads
        var chunks: [Data] = []
        var offset = 0
        var chunkSize = 1
        while offset < fullData.count {
            let end = min(offset + chunkSize, fullData.count)
            chunks.append(fullData[offset..<end])
            offset = end
            chunkSize = (chunkSize % 7) + 1  // Vary chunk sizes: 1,2,3,4,5,6,7,1,2,...
        }
        
        // Feed all chunks
        for chunk in chunks {
            session.simulateReceivedDataForTesting(chunk)
        }
        
        // Verify all chunks arrived in order
        XCTAssertEqual(delegate.receivedDataCalls.count, chunks.count,
                       "Every chunk should be delivered")
        
        // Reconstruct the stream from delegate data and verify it matches original
        let reconstructed = delegate.receivedDataCalls.reduce(Data()) { $0 + $1.data }
        XCTAssertEqual(reconstructed, fullData,
                       "Reconstructed stream must exactly match original — any reordering would corrupt DCS state machine")
    }
    
    // MARK: - 11. Awaiting Control Mode Suppression (#68)
    
    /// When in .awaitingControlMode, data without DCS 1000p should be suppressed
    /// (not forwarded to delegate). This prevents shell echo of `exec tmux -CC`
    /// from rendering on screen.
    @MainActor
    func testAwaitingControlModeSuppressesNonDCSData() {
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Enter awaitingControlMode state
        session.setSessionDiscoveryStateAwaitingForTesting()
        
        // Simulate shell echo data (no DCS 1000p)
        let shellEcho = "exec tmux -CC new-session -A -s 'geistty-1'\r\n".data(using: .utf8)!
        session.simulateReceivedDataForTesting(shellEcho)
        
        // Data should NOT be forwarded to delegate
        XCTAssertEqual(delegate.receivedDataCalls.count, 0,
                       "Shell echo should be suppressed while awaiting control mode")
        XCTAssertTrue(session.earlyReceiveBufferForTesting.isEmpty,
                      "Shell echo should not be buffered either — it's discarded")
        // Should still be in awaitingControlMode
        XCTAssertTrue(session.isAwaitingControlModeForTesting,
                      "Should remain in awaitingControlMode until DCS 1000p arrives")
    }
    
    // MARK: - 12. Awaiting Control Mode Detects DCS 1000p (#68)
    
    /// When DCS 1000p arrives while in .awaitingControlMode, the state should
    /// transition to .idle and the DCS data should be forwarded to the delegate.
    @MainActor
    func testAwaitingControlModeForwardsDCS1000p() {
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Enter awaitingControlMode state
        session.setSessionDiscoveryStateAwaitingForTesting()
        
        // Simulate DCS 1000p arriving (tmux control mode activation)
        let dcs1000p = "\u{1b}P1000p".data(using: .utf8)!
        session.simulateReceivedDataForTesting(dcs1000p)
        
        // DCS data should be forwarded to delegate
        XCTAssertEqual(delegate.receivedDataCalls.count, 1,
                       "DCS 1000p should be forwarded to delegate")
        XCTAssertEqual(delegate.receivedDataCalls[0].data, dcs1000p,
                       "Forwarded data should be the DCS 1000p sequence")
        // Should transition to idle
        XCTAssertTrue(session.isSessionDiscoveryIdleForTesting,
                      "Should transition to idle after DCS 1000p detected")
    }
    
    // MARK: - 13. Shell Echo Before DCS 1000p in Same Chunk (#68)
    
    /// When a single SSH chunk contains both shell echo and DCS 1000p,
    /// only the DCS 1000p and data after it should be forwarded.
    @MainActor
    func testAwaitingControlModeDiscardsPrefixBeforeDCS() {
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Enter awaitingControlMode state
        session.setSessionDiscoveryStateAwaitingForTesting()
        
        // Simulate a chunk with shell echo + DCS 1000p + tmux output
        let shellEcho = "exec tmux -CC new-session -A -s 'geistty-1'\r\n"
        let dcsAndOutput = "\u{1b}P1000p%output %0 hello\n"
        let combined = (shellEcho + dcsAndOutput).data(using: .utf8)!
        session.simulateReceivedDataForTesting(combined)
        
        // Only DCS 1000p onward should be forwarded
        let expectedForwarded = dcsAndOutput.data(using: .utf8)!
        XCTAssertEqual(delegate.receivedDataCalls.count, 1,
                       "Should forward exactly one chunk (DCS + trailing data)")
        XCTAssertEqual(delegate.receivedDataCalls[0].data, expectedForwarded,
                       "Should discard shell echo and forward from DCS 1000p onward")
        XCTAssertTrue(session.isSessionDiscoveryIdleForTesting,
                      "Should transition to idle")
    }
    
    // MARK: - 14. Multiple Suppressed Chunks Before DCS (#68)
    
    /// Multiple data chunks may arrive before DCS 1000p. All should be suppressed.
    @MainActor
    func testAwaitingControlModeSuppressesMultipleChunks() {
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Enter awaitingControlMode state
        session.setSessionDiscoveryStateAwaitingForTesting()
        
        // Simulate several chunks of shell output before DCS 1000p
        let chunk1 = "exec tmux".data(using: .utf8)!
        let chunk2 = " -CC new-session -A -s 'geistty-1'\r\n".data(using: .utf8)!
        let chunk3 = "some other shell output\r\n".data(using: .utf8)!
        
        session.simulateReceivedDataForTesting(chunk1)
        session.simulateReceivedDataForTesting(chunk2)
        session.simulateReceivedDataForTesting(chunk3)
        
        // All should be suppressed
        XCTAssertEqual(delegate.receivedDataCalls.count, 0,
                       "All pre-DCS chunks should be suppressed")
        XCTAssertTrue(session.isAwaitingControlModeForTesting,
                      "Should still be awaiting control mode")
        
        // Now DCS 1000p arrives
        let dcs = "\u{1b}P1000p".data(using: .utf8)!
        session.simulateReceivedDataForTesting(dcs)
        
        // Only this chunk should be forwarded
        XCTAssertEqual(delegate.receivedDataCalls.count, 1,
                       "DCS 1000p should be forwarded")
        XCTAssertTrue(session.isSessionDiscoveryIdleForTesting,
                      "Should transition to idle")
    }
    
    // MARK: - 15. Normal Data After Control Mode Activated (#68)
    
    /// After DCS 1000p arrives and state returns to .idle, subsequent data
    /// should flow normally to the delegate.
    @MainActor
    func testNormalDataFlowAfterControlModeActivated() {
        let session = SSHSession()
        let delegate = MockSSHSessionDelegate()
        session.delegate = delegate
        
        // Enter awaitingControlMode, then activate with DCS 1000p
        session.setSessionDiscoveryStateAwaitingForTesting()
        let dcs = "\u{1b}P1000p".data(using: .utf8)!
        session.simulateReceivedDataForTesting(dcs)
        
        XCTAssertTrue(session.isSessionDiscoveryIdleForTesting)
        
        // Subsequent data should flow normally
        let normalData = "%output %0 world\n".data(using: .utf8)!
        session.simulateReceivedDataForTesting(normalData)
        
        XCTAssertEqual(delegate.receivedDataCalls.count, 2,
                       "DCS + subsequent data = 2 delegate calls")
        XCTAssertEqual(delegate.receivedDataCalls[1].data, normalData,
                       "Normal data should flow through after idle")
    }
    
    // MARK: - 16. Disconnect Clears Awaiting State (#68)
    
    /// Disconnecting while in .awaitingControlMode should reset to .idle.
    @MainActor
    func testDisconnectClearsAwaitingControlMode() {
        let session = SSHSession()
        
        session.setSessionDiscoveryStateAwaitingForTesting()
        XCTAssertTrue(session.isAwaitingControlModeForTesting)
        
        session.disconnect()
        
        XCTAssertTrue(session.isSessionDiscoveryIdleForTesting,
                      "Disconnect should reset awaitingControlMode to idle")
    }
}
