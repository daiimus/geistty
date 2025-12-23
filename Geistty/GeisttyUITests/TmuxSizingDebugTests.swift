//
//  TmuxSizingDebugTests.swift
//  GeisttyUITests
//
//  Specific debug tests for the tmux pane sizing issues
//  These tests capture detailed screenshots to help diagnose problems
//

import XCTest

/// Debug tests specifically for diagnosing tmux pane sizing issues
final class TmuxSizingDebugTests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = true  // Keep going to capture all screenshots
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--debug-sizing"]
        app.launch()
    }
    
    override func tearDownWithError() throws {
        // Always take final screenshot
        takeScreenshot(name: "Final-State")
        app = nil
    }
    
    // MARK: - Single Split Sizing
    
    /// Debug test for horizontal split sizing issue
    /// Captures detailed screenshots before and after split
    func testDebugHorizontalSplitSizing() throws {
        try skipIfNotConnected()
        
        // 1. Capture full screen before split
        takeScreenshot(name: "DEBUG-1-BeforeSplit-FullScreen")
        
        // 2. Log screen dimensions
        let window = app.windows.firstMatch
        print("📐 Window frame: \(window.frame)")
        
        // 3. Perform horizontal split
        print("🔄 Triggering Cmd+D for horizontal split...")
        app.typeKey("d", modifierFlags: .command)
        
        // 4. Wait for split to complete
        Thread.sleep(forTimeInterval: 1.5)
        
        // 5. Capture after split
        takeScreenshot(name: "DEBUG-2-AfterSplit-FullScreen")
        
        // 6. Log any visible elements that might indicate pane bounds
        logVisibleElements()
        
        // 7. Type something in each pane to verify they're active
        app.typeText("echo 'left pane'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "DEBUG-3-LeftPaneTyped")
        
        // 8. Switch to other pane
        app.typeKey("]", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        
        app.typeText("echo 'right pane'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "DEBUG-4-RightPaneTyped")
        
        print("✅ Debug split test complete - check screenshots")
    }
    
    /// Debug test for vertical split sizing
    func testDebugVerticalSplitSizing() throws {
        try skipIfNotConnected()
        
        takeScreenshot(name: "DEBUG-V-1-Before")
        
        print("🔄 Triggering Cmd+Shift+D for vertical split...")
        app.typeKey("d", modifierFlags: [.command, .shift])
        
        Thread.sleep(forTimeInterval: 1.5)
        
        takeScreenshot(name: "DEBUG-V-2-After")
        
        logVisibleElements()
    }
    
    /// Debug test for 4-pane grid sizing
    func testDebug4PaneGrid() throws {
        try skipIfNotConnected()
        
        takeScreenshot(name: "DEBUG-4P-1-Initial")
        
        // Create 2x2 grid
        // First horizontal split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "DEBUG-4P-2-After1stHorizontal")
        
        // Go to left pane
        app.typeKey("[", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        
        // Vertical split on left
        app.typeKey("d", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "DEBUG-4P-3-After1stVertical")
        
        // Go to right pane
        app.typeKey("]", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("]", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        
        // Vertical split on right
        app.typeKey("d", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "DEBUG-4P-4-Final4Panes")
        
        // Type in each pane to verify sizes
        for i in 0..<4 {
            app.typeText("echo 'pane \(i+1)'\n")
            Thread.sleep(forTimeInterval: 0.5)
            takeScreenshot(name: "DEBUG-4P-5-Pane\(i+1)Typed")
            app.typeKey("]", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.3)
        }
        
        logVisibleElements()
    }
    
    // MARK: - Orientation Changes
    
    /// Debug test for orientation change handling
    func testDebugOrientationSizing() throws {
        try skipIfNotConnected()
        
        // Create a split first
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "DEBUG-O-1-Portrait-Split")
        
        // Rotate to landscape
        print("🔄 Rotating to landscape...")
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2.0)
        takeScreenshot(name: "DEBUG-O-2-Landscape-Split")
        
        logVisibleElements()
        
        // Rotate back
        print("🔄 Rotating back to portrait...")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2.0)
        takeScreenshot(name: "DEBUG-O-3-PortraitAgain-Split")
        
        logVisibleElements()
    }
    
    // MARK: - Window Resizing (Stage Manager)
    
    /// Debug test for window resize handling (iPad Stage Manager)
    func testDebugWindowResize() throws {
        try skipIfNotConnected()
        
        // Create a split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "DEBUG-R-1-Initial")
        
        // Note: XCUITest can't directly resize windows in Stage Manager
        // This test captures the initial state for manual testing
        
        print("📝 For window resize testing:")
        print("   1. Enable Stage Manager on iPad")
        print("   2. Resize the Geistty window")
        print("   3. Observe if panes resize correctly")
        print("   4. Check if refresh-client -C is sent to tmux")
        
        logVisibleElements()
    }
    
    // MARK: - Multi-Window Tests
    
    /// Debug test for multiple tmux windows
    func testDebugMultipleWindows() throws {
        try skipIfNotConnected()
        
        takeScreenshot(name: "DEBUG-W-1-Initial")
        
        // Create new window
        print("🔄 Creating new tmux window...")
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "DEBUG-W-2-AfterNewWindow")
        
        // Check for window picker UI
        let windowPicker = app.otherElements["WindowPicker"]
        if windowPicker.exists {
            print("✅ Window picker found")
            takeScreenshot(name: "DEBUG-W-3-WindowPicker")
        } else {
            print("⚠️ Window picker not found - may be in tab bar")
        }
        
        // Switch back to first window
        app.typeKey("[", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "DEBUG-W-4-BackToWindow1")
        
        logVisibleElements()
    }
    
    // MARK: - Helper Methods
    
    private func skipIfNotConnected() throws {
        let connectionUI = app.buttons["New Connection"]
        if connectionUI.waitForExistence(timeout: 3) {
            throw XCTSkip("Not connected - need active SSH connection for these tests")
        }
    }
    
    private func takeScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("📸 Screenshot captured: \(name)")
    }
    
    private func logVisibleElements() {
        print("📋 Visible UI Elements:")
        print("   Windows: \(app.windows.count)")
        print("   Other Elements: \(app.otherElements.count)")
        
        // Log any elements with accessibility identifiers
        for element in app.otherElements.allElementsBoundByIndex {
            if !element.identifier.isEmpty {
                print("   - \(element.identifier): \(element.frame)")
            }
        }
    }
}
