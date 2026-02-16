//
//  MockSSHSessionDelegate.swift
//  GeisttyTests
//
//  Mock implementation of SSHSessionDelegate for unit testing.
//  Records all delegate calls with arguments for verification.
//

import Foundation
@testable import Geistty

/// Mock delegate that records all SSHSession delegate calls.
///
/// Usage:
/// ```swift
/// let delegate = MockSSHSessionDelegate()
/// session.delegate = delegate
/// // ... trigger code that calls delegate methods ...
/// XCTAssertEqual(delegate.receivedDataCalls.count, 3)
/// ```
@MainActor
final class MockSSHSessionDelegate: SSHSessionDelegate {
    
    // MARK: - Call Recording
    
    /// Sessions passed to `sshSessionDidConnect(_:)`
    var didConnectCalls: [SSHSession] = []
    
    /// (session, data) tuples passed to `sshSession(_:didReceiveData:)`
    var receivedDataCalls: [(session: SSHSession, data: Data)] = []
    
    /// (session, error) tuples passed to `sshSession(_:didDisconnectWithError:)`
    var didDisconnectCalls: [(session: SSHSession, error: Error?)] = []
    
    /// (session, health) tuples passed to `sshSession(_:healthDidChange:)`
    var healthChangeCalls: [(session: SSHSession, health: ConnectionHealth)] = []
    
    // MARK: - SSHSessionDelegate
    
    // SSHSessionDelegate is not @MainActor, but all callers (SSHSession.handleReceivedData,
    // TmuxConnectionLifecycleTests, etc.) run on @MainActor. Since MockSSHSessionDelegate
    // is @MainActor, these calls execute synchronously — no Task hop needed.
    // The previous nonisolated + Task pattern caused receivedDataCalls to be populated
    // asynchronously, making ordering assertions unreliable.
    
    func sshSessionDidConnect(_ session: SSHSession) {
        self.didConnectCalls.append(session)
    }
    
    func sshSession(_ session: SSHSession, didReceiveData data: Data) {
        self.receivedDataCalls.append((session: session, data: data))
    }
    
    func sshSession(_ session: SSHSession, didDisconnectWithError error: Error?) {
        self.didDisconnectCalls.append((session: session, error: error))
    }
    
    func sshSession(_ session: SSHSession, healthDidChange health: ConnectionHealth) {
        self.healthChangeCalls.append((session: session, health: health))
    }
    
    // MARK: - Reset
    
    /// Clear all recorded calls
    func resetCallTracking() {
        didConnectCalls.removeAll()
        receivedDataCalls.removeAll()
        didDisconnectCalls.removeAll()
        healthChangeCalls.removeAll()
    }
}
