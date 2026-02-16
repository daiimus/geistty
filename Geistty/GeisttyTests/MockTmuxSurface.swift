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
    
    /// Value returned by `tmuxWindowCount`
    var stubbedWindowCount: Int = 0
    
    /// Value returned by `getAllTmuxWindows()`
    var stubbedWindows: [TmuxWindowInfo] = []
    
    /// Values returned by `getTmuxWindowLayout(at:)`, indexed by position.
    /// Returns nil for out-of-bounds indices.
    var stubbedWindowLayouts: [String?] = []
    
    /// Value returned by `tmuxActiveWindowId`
    var stubbedActiveWindowId: Int = -1
    
    // MARK: - Call Tracking
    
    /// Pane IDs passed to `setActiveTmuxPane(_:)`, in order
    var setActiveTmuxPaneCalls: [Int] = []
    
    /// Texts passed to `sendText(_:)`, in order
    var sendTextCalls: [String] = []
    
    /// Number of times `getTmuxPaneIds()` was called
    var getTmuxPaneIdsCallCount: Int = 0
    
    /// Number of times `getAllTmuxWindows()` was called
    var getAllTmuxWindowsCallCount: Int = 0
    
    /// Indices passed to `getTmuxWindowLayout(at:)`, in order
    var getTmuxWindowLayoutCalls: [Int] = []
    
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
    
    func sendText(_ text: String) {
        sendTextCalls.append(text)
    }
    
    // MARK: - Reset
    
    /// Clear all call tracking (but keep stubbed values)
    func resetCallTracking() {
        setActiveTmuxPaneCalls.removeAll()
        sendTextCalls.removeAll()
        getTmuxPaneIdsCallCount = 0
        getAllTmuxWindowsCallCount = 0
        getTmuxWindowLayoutCalls.removeAll()
    }
}
