//
//  MockTmuxSurface.swift
//  GeisttyTests
//
//  Mock implementation of TmuxSurfaceProtocol for unit testing.
//  Provides configurable return values and call tracking for all
//  tmux C API methods without requiring a real GhosttyKit surface.
//

import Foundation
@testable import Geistty

/// Mock surface for testing tmux lifecycle code.
///
/// Usage:
/// ```swift
/// let mock = MockTmuxSurface()
/// mock.stubbedPaneCount = 2
/// mock.stubbedPaneIds = [0, 1]
/// mock.stubbedSetActivePaneResult = true
///
/// session.tmuxSurfaceOverride = mock
/// // ... trigger lifecycle code ...
///
/// XCTAssertEqual(mock.setActiveTmuxPaneCalls, [0])
/// ```
@MainActor
final class MockTmuxSurface: TmuxSurfaceProtocol {
    
    // MARK: - Stubbed Return Values
    
    /// Value returned by `tmuxPaneCount`
    var stubbedPaneCount: Int = 0
    
    /// Value returned by `getTmuxPaneIds()`
    var stubbedPaneIds: [Int] = []
    
    /// Value returned by `setActiveTmuxPane(_:)`
    var stubbedSetActivePaneResult: Bool = true
    
    /// Value returned by `setActiveTmuxPaneInputOnly(_:)`
    var stubbedSetActivePaneInputOnlyResult: Bool = true
    
    /// Value returned by `tmuxWindowCount`
    var stubbedWindowCount: Int = 0
    
    /// Value returned by `getAllTmuxWindows()`
    var stubbedWindows: [TmuxWindowInfo] = []
    
    /// Values returned by `getTmuxWindowLayout(at:)`, indexed by position.
    /// Returns nil for out-of-bounds indices.
    var stubbedWindowLayouts: [String?] = []
    
    /// Value returned by `tmuxActiveWindowId`
    var stubbedActiveWindowId: Int = -1
    
    /// Values returned by `tmuxWindowFocusedPaneId(at:)`, indexed by position.
    /// Returns -1 for out-of-bounds indices.
    var stubbedWindowFocusedPaneIds: [Int] = []
    
    // MARK: - Call Tracking
    
    /// Pane IDs passed to `setActiveTmuxPane(_:)`, in order
    var setActiveTmuxPaneCalls: [Int] = []
    
    /// Pane IDs passed to `setActiveTmuxPaneInputOnly(_:)`, in order
    var setActiveTmuxPaneInputOnlyCalls: [Int] = []
    
    /// Texts passed to `sendText(_:)`, in order
    var sendTextCalls: [String] = []
    
    /// Commands passed to `sendTmuxCommand(_:)`, in order
    var sendTmuxCommandCalls: [String] = []
    
    /// Value returned by `sendTmuxCommand(_:)`
    var stubbedSendTmuxCommandResult: Bool = true
    
    /// Number of times `getTmuxPaneIds()` was called
    var getTmuxPaneIdsCallCount: Int = 0
    
    /// Number of times `getAllTmuxWindows()` was called
    var getAllTmuxWindowsCallCount: Int = 0
    
    /// Indices passed to `getTmuxWindowLayout(at:)`, in order
    var getTmuxWindowLayoutCalls: [Int] = []
    
    /// Indices passed to `tmuxWindowFocusedPaneId(at:)`, in order
    var tmuxWindowFocusedPaneIdCalls: [Int] = []
    
    // MARK: - TmuxSurfaceProtocol
    
    var tmuxPaneCount: Int {
        stubbedPaneCount
    }
    
    func getTmuxPaneIds() -> [Int] {
        getTmuxPaneIdsCallCount += 1
        return stubbedPaneIds
    }
    
    @discardableResult
    func setActiveTmuxPane(_ paneId: Int) -> Bool {
        setActiveTmuxPaneCalls.append(paneId)
        return stubbedSetActivePaneResult
    }
    
    @discardableResult
    func setActiveTmuxPaneInputOnly(_ paneId: Int) -> Bool {
        setActiveTmuxPaneInputOnlyCalls.append(paneId)
        return stubbedSetActivePaneInputOnlyResult
    }
    
    var tmuxWindowCount: Int {
        stubbedWindowCount
    }
    
    func getAllTmuxWindows() -> [TmuxWindowInfo] {
        getAllTmuxWindowsCallCount += 1
        return stubbedWindows
    }
    
    func getTmuxWindowLayout(at index: Int) -> String? {
        getTmuxWindowLayoutCalls.append(index)
        guard index < stubbedWindowLayouts.count else { return nil }
        return stubbedWindowLayouts[index]
    }
    
    var tmuxActiveWindowId: Int {
        stubbedActiveWindowId
    }
    
    func tmuxWindowFocusedPaneId(at index: Int) -> Int {
        tmuxWindowFocusedPaneIdCalls.append(index)
        guard index < stubbedWindowFocusedPaneIds.count else { return -1 }
        return stubbedWindowFocusedPaneIds[index]
    }
    
    func sendText(_ text: String) {
        sendTextCalls.append(text)
    }
    
    @discardableResult
    func sendTmuxCommand(_ command: String) -> Bool {
        sendTmuxCommandCalls.append(command)
        return stubbedSendTmuxCommandResult
    }
    
    // MARK: - Reset
    
    /// Clear all call tracking (but keep stubbed values)
    func resetCallTracking() {
        setActiveTmuxPaneCalls.removeAll()
        setActiveTmuxPaneInputOnlyCalls.removeAll()
        sendTextCalls.removeAll()
        sendTmuxCommandCalls.removeAll()
        getTmuxPaneIdsCallCount = 0
        getAllTmuxWindowsCallCount = 0
        getTmuxWindowLayoutCalls.removeAll()
        tmuxWindowFocusedPaneIdCalls.removeAll()
    }
}
