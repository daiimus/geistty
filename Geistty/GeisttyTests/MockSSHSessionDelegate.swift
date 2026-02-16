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
    
    nonisolated func sshSessionDidConnect(_ session: SSHSession) {
        Task { @MainActor in
            self.didConnectCalls.append(session)
        }
    }
    
    nonisolated func sshSession(_ session: SSHSession, didReceiveData data: Data) {
        Task { @MainActor in
            self.receivedDataCalls.append((session: session, data: data))
        }
    }
    
    nonisolated func sshSession(_ session: SSHSession, didDisconnectWithError error: Error?) {
        Task { @MainActor in
            self.didDisconnectCalls.append((session: session, error: error))
        }
    }
    
    nonisolated func sshSession(_ session: SSHSession, healthDidChange health: ConnectionHealth) {
        Task { @MainActor in
            self.healthChangeCalls.append((session: session, health: health))
        }
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
