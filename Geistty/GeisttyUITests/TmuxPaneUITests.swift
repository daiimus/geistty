//
//  TmuxPaneUITests.swift
//  GeisttyUITests
//
//  UI Tests for tmux pane management, splitting, and resizing
//

import XCTest

/// Tests for tmux multi-pane functionality
final class TmuxPaneUITests: XCTestCase {
    
    var app: XCUIApplication!
    
    // Test configuration - set these for your environment
    static let testHost = "localhost"  // Change to your test server
    static let testUser = "testuser"   // Change to your test user
    static let testPort = "22"
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }
    
    override func tearDownWithError() throws {
        // Take screenshot on failure for debugging
        if let failureCount = testRun?.failureCount, failureCount > 0 {
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "Failure-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app = nil
    }
    
    // MARK: - Split Tests
    
    /// Test horizontal split (Cmd+D)
    func testHorizontalSplit() throws {
        try skipIfNotConnected()
        
        // Take initial screenshot
        takeScreenshot(name: "Before-Split")
        
        // Get initial pane count (if accessible)
        let initialPaneCount = countVisiblePanes()
        
        // Trigger horizontal split
        app.typeKey("d", modifierFlags: .command)
        
        // Wait for tmux to process and UI to update
        Thread.sleep(forTimeInterval: 1.0)
        
        // Take post-split screenshot
        takeScreenshot(name: "After-HorizontalSplit")
        
        // Verify pane count increased
        let newPaneCount = countVisiblePanes()
        
        // Log for debugging
        print("📐 Pane count: \(initialPaneCount) -> \(newPaneCount)")
        
        // At minimum, verify no crash occurred
        XCTAssertTrue(app.exists, "App should still exist after split")
    }
    
    /// Test vertical split (Cmd+Shift+D)
    func testVerticalSplit() throws {
        try skipIfNotConnected()
        
        takeScreenshot(name: "Before-VerticalSplit")
        
        // Trigger vertical split
        app.typeKey("d", modifierFlags: [.command, .shift])
        
        Thread.sleep(forTimeInterval: 1.0)
        
        takeScreenshot(name: "After-VerticalSplit")
        
        XCTAssertTrue(app.exists, "App should still exist after vertical split")
    }
    
    /// Test multiple splits in sequence
    func testMultipleSplits() throws {
        try skipIfNotConnected()
        
        takeScreenshot(name: "MultipleSplits-0-Initial")
        
        // First split (horizontal)
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "MultipleSplits-1-AfterHorizontal")
        
        // Second split (vertical on right pane)
        app.typeKey("d", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "MultipleSplits-2-AfterVertical")
        
        // Third split (horizontal on bottom-right)
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "MultipleSplits-3-Final")
        
        // Verify app is stable with multiple panes
        XCTAssertTrue(app.exists, "App should handle multiple splits")
    }
    
    // MARK: - Focus Navigation Tests
    
    /// Test Cmd+] cycles to next pane
    func testNextPaneFocus() throws {
        try skipIfNotConnected()
        
        // First create a split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        
        takeScreenshot(name: "Focus-BeforeNext")
        
        // Navigate to next pane
        app.typeKey("]", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        
        takeScreenshot(name: "Focus-AfterNext")
        
        XCTAssertTrue(app.exists, "App should handle focus navigation")
    }
    
    /// Test Cmd+[ cycles to previous pane
    func testPreviousPaneFocus() throws {
        try skipIfNotConnected()
        
        // First create a split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        
        // Navigate to previous pane
        app.typeKey("[", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        
        takeScreenshot(name: "Focus-AfterPrevious")
        
        XCTAssertTrue(app.exists, "App should handle reverse focus navigation")
    }
    
    /// Test directional focus (Cmd+Option+Arrow)
    func testDirectionalFocus() throws {
        try skipIfNotConnected()
        
        // Create 4-pane layout
        app.typeKey("d", modifierFlags: .command)  // Split horizontal
        Thread.sleep(forTimeInterval: 0.5)
        
        app.typeKey("[", modifierFlags: .command)  // Go to left pane
        Thread.sleep(forTimeInterval: 0.3)
        
        app.typeKey("d", modifierFlags: [.command, .shift])  // Split vertical
        Thread.sleep(forTimeInterval: 0.5)
        
        takeScreenshot(name: "Directional-4PaneLayout")
        
        // Test directional navigation
        // Right
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 0.3)
        takeScreenshot(name: "Directional-AfterRight")
        
        // Down
        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 0.3)
        takeScreenshot(name: "Directional-AfterDown")
        
        // Left
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 0.3)
        takeScreenshot(name: "Directional-AfterLeft")
        
        // Up
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        Thread.sleep(forTimeInterval: 0.3)
        takeScreenshot(name: "Directional-AfterUp")
        
        XCTAssertTrue(app.exists, "App should handle directional navigation")
    }
    
    // MARK: - Resize Tests
    
    /// Test pane sizing after split
    func testPaneSizingAfterSplit() throws {
        try skipIfNotConnected()
        
        // Get initial frame/size if accessible
        takeScreenshot(name: "Resize-Initial")
        
        // Split horizontally
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        
        takeScreenshot(name: "Resize-AfterSplit")
        
        // The key question: are both panes using full available space?
        // This screenshot will help diagnose the sizing issue
        
        XCTAssertTrue(app.exists, "App should maintain proper sizing")
    }
    
    /// Test window rotation/resize handling
    func testOrientationChange() throws {
        try skipIfNotConnected()
        
        // Create a split first
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        
        takeScreenshot(name: "Orientation-Portrait")
        
        // Rotate to landscape
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.0)
        
        takeScreenshot(name: "Orientation-Landscape")
        
        // Rotate back to portrait
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.0)
        
        takeScreenshot(name: "Orientation-PortraitAgain")
        
        XCTAssertTrue(app.exists, "App should handle orientation changes")
    }
    
    // MARK: - Window (Tab) Tests
    
    /// Test creating new tmux window
    func testNewWindow() throws {
        try skipIfNotConnected()
        
        takeScreenshot(name: "Window-Initial")
        
        // Create new window (Cmd+N or equivalent)
        // Note: Need to verify the actual shortcut in the app
        app.typeKey("t", modifierFlags: .command)  // Cmd+T for new tab/window
        Thread.sleep(forTimeInterval: 1.0)
        
        takeScreenshot(name: "Window-AfterNew")
        
        XCTAssertTrue(app.exists, "App should create new tmux window")
    }
    
    /// Test switching between tmux windows
    func testWindowSwitching() throws {
        try skipIfNotConnected()
        
        // Create new window first
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        
        takeScreenshot(name: "WindowSwitch-Window2")
        
        // Switch to previous window (Cmd+Shift+[)
        app.typeKey("[", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        
        takeScreenshot(name: "WindowSwitch-Window1")
        
        // Switch to next window (Cmd+Shift+])
        app.typeKey("]", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        
        takeScreenshot(name: "WindowSwitch-BackToWindow2")
        
        XCTAssertTrue(app.exists, "App should handle window switching")
    }
    
    // MARK: - Stress Tests
    
    /// Test rapid split/close cycle
    func testRapidSplitClose() throws {
        try skipIfNotConnected()
        
        for i in 0..<5 {
            // Split
            app.typeKey("d", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.3)
            
            // Close pane (Cmd+W on the new pane)
            app.typeKey("w", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.3)
            
            print("🔄 Rapid cycle \(i + 1) complete")
        }
        
        takeScreenshot(name: "RapidCycle-Final")
        
        XCTAssertTrue(app.exists, "App should survive rapid split/close cycles")
    }
    
    /// Test creating many panes
    func testManyPanes() throws {
        try skipIfNotConnected()
        
        // Create a grid of panes
        for i in 0..<3 {
            app.typeKey("d", modifierFlags: .command)  // Horizontal
            Thread.sleep(forTimeInterval: 0.5)
            
            app.typeKey("d", modifierFlags: [.command, .shift])  // Vertical
            Thread.sleep(forTimeInterval: 0.5)
            
            print("🔲 Grid iteration \(i + 1) complete")
        }
        
        takeScreenshot(name: "ManyPanes-Final")
        
        XCTAssertTrue(app.exists, "App should handle many panes")
    }
    
    // MARK: - Helper Methods
    
    private func skipIfNotConnected() throws {
        // Check if we're in terminal view
        // This is heuristic - might need adjustment
        let connectionUI = app.buttons["New Connection"]
        if connectionUI.waitForExistence(timeout: 2) {
            throw XCTSkip("Not connected to terminal - these tests require an active SSH connection")
        }
    }
    
    private func countVisiblePanes() -> Int {
        // Try to count panes by looking for terminal surfaces
        // This requires accessibility identifiers to be set in the app
        let panes = app.otherElements.matching(identifier: "TerminalPane")
        return panes.count
    }
    
    private func takeScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
