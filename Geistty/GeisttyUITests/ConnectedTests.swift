//
//  ConnectedTests.swift
//  GeisttyUITests
//
//  Tests that require an actual SSH connection
//  Uses TestConfig.local.swift for credentials (gitignored)
//

import os
import XCTest

private let logger = Logger(subsystem: "com.geistty.uitests", category: "ConnectedTests")

/// Tests that connect to a real SSH server for testing tmux integration
/// Requires TestConfig.local.swift to be configured with valid credentials
final class ConnectedTests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        // Skip all tests if config isn't set up
        guard TestConfig.isConfigured else {
            throw XCTSkip("TestConfig.local.swift not configured - isConfigured is false")
        }
        
        continueAfterFailure = true
        app = XCUIApplication()
        
        // Pass connection details via launch arguments
        app.launchArguments = [
            "--ui-testing",
            "--test-host", TestConfig.sshHost,
            "--test-port", String(TestConfig.sshPort),
            "--test-user", TestConfig.sshUsername,
            "--test-key", TestConfig.keyFilePath
        ]
        
        logger.info("Launching app with test arguments")
        app.launch()
        logger.info("App launched")
    }
    
    override func tearDownWithError() throws {
        takeScreenshot(name: "Test-End-State")
        app = nil
    }
    
    // MARK: - Connection Test
    
    /// Test connecting to the SSH server via Quick Connect
    func testQuickConnectToTestServer() throws {
        takeScreenshot(name: "01-Launch")
        
        // Look for Quick Connect button by accessibility identifier
        let quickConnectButton = app.buttons["QuickConnectButton"]
        if quickConnectButton.waitForExistence(timeout: 5) {
            quickConnectButton.tap()
            takeScreenshot(name: "02-QuickConnectTapped")
        } else {
            logger.warning("QuickConnectButton not found, looking for alternatives")
            // Also try text-based lookup
            let altButton = app.buttons["Quick Connect"]
            if altButton.waitForExistence(timeout: 2) {
                altButton.tap()
                takeScreenshot(name: "02-QuickConnectTapped")
            }
        }
        
        // Fill in connection details
        fillConnectionDetails()
        takeScreenshot(name: "03-DetailsEntered")
        
        // Tap Connect by accessibility identifier
        let connectButton = app.buttons["ConnectButton"]
        if connectButton.waitForExistence(timeout: 3) {
            connectButton.tap()
        } else {
            // Fallback to text
            let altConnect = app.buttons["Connect"]
            if altConnect.waitForExistence(timeout: 2) {
                altConnect.tap()
            }
        }
        
        // Wait for connection and terminal to appear
        let connected = waitForTerminal(timeout: TestConfig.connectionTimeout)
        takeScreenshot(name: "04-AfterConnect")
        
        XCTAssertTrue(connected, "Should connect to test server")
        
        if connected {
            // Type a command to verify it's working
            Thread.sleep(forTimeInterval: 1.0)
            app.typeText("echo 'Hello from Geistty UI Test!'\n")
            Thread.sleep(forTimeInterval: 0.5)
            takeScreenshot(name: "05-CommandExecuted")
        }
    }
    
    /// Test tmux pane splitting after connection
    func testTmuxSplitAfterConnect() throws {
        // First connect
        try connectToTestServer()
        takeScreenshot(name: "Split-01-Connected")
        
        // Wait for tmux to initialize
        Thread.sleep(forTimeInterval: 2.0)
        
        // Horizontal split (Cmd+D)
        logger.debug("Performing horizontal split (Cmd+D)")
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(name: "Split-02-AfterHorizontalSplit")
        
        // Type in right pane
        app.typeText("echo 'RIGHT PANE'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "Split-03-RightPaneTyped")
        
        // Switch to left pane (Cmd+[)
        app.typeKey("[", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        
        // Type in left pane
        app.typeText("echo 'LEFT PANE'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "Split-04-LeftPaneTyped")
        
        // Log element info
        logPaneElements()
    }
    
    /// Test vertical split
    func testVerticalSplit() throws {
        try connectToTestServer()
        Thread.sleep(forTimeInterval: 2.0)
        takeScreenshot(name: "VSplit-01-Connected")
        
        // Vertical split (Cmd+Shift+D)
        logger.debug("Performing vertical split (Cmd+Shift+D)")
        app.typeKey("d", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(name: "VSplit-02-AfterSplit")
        
        // Type in bottom pane
        app.typeText("echo 'BOTTOM PANE'\n")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "VSplit-03-BottomPaneTyped")
        
        logPaneElements()
    }
    
    /// Test quad split (2x2 grid)
    func testQuadSplit() throws {
        try connectToTestServer()
        Thread.sleep(forTimeInterval: 2.0)
        takeScreenshot(name: "Quad-01-Connected")
        
        // First horizontal split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "Quad-02-FirstSplit")
        
        // Vertical split on right pane
        app.typeKey("d", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "Quad-03-SecondSplit")
        
        // Go to left pane
        app.typeKey("[", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        
        // Vertical split on left pane
        app.typeKey("d", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "Quad-04-FourPanes")
        
        // Label each pane
        labelAllPanes()
        takeScreenshot(name: "Quad-05-AllLabeled")
        
        logPaneElements()
    }
    
    /// Test window resize behavior
    func testWindowResize() throws {
        try connectToTestServer()
        Thread.sleep(forTimeInterval: 2.0)
        
        // Create a split first
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "Resize-01-SplitCreated")
        
        // Log initial frame
        let window = app.windows.firstMatch
        logger.debug("Initial window frame: \(String(describing: window.frame))")
        
        // Note: Can't programmatically resize window in UI tests easily
        // But we can capture the state and rotate device
        takeScreenshot(name: "Resize-02-Portrait")
        
        // Rotate to landscape
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(name: "Resize-03-Landscape")
        logger.debug("Landscape window frame: \(String(describing: window.frame))")
        
        // Rotate back
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.5)
        takeScreenshot(name: "Resize-04-BackToPortrait")
        logger.debug("Portrait again window frame: \(String(describing: window.frame))")
        
        logPaneElements()
    }
    
    // MARK: - Helper Methods
    
    private func connectToTestServer() throws {
        // Try Quick Connect flow using accessibility identifiers
        let quickConnect = app.buttons["QuickConnectButton"]
        if quickConnect.waitForExistence(timeout: 3) {
            quickConnect.tap()
            fillConnectionDetails()
            
            let connectButton = app.buttons["ConnectButton"]
            if connectButton.waitForExistence(timeout: 2) {
                connectButton.tap()
            } else {
                // Fallback
                let altConnect = app.buttons["Connect"]
                if altConnect.exists {
                    altConnect.tap()
                }
            }
        } else {
            // Fallback to text-based lookup
            let altQuickConnect = app.buttons["Quick Connect"]
            if altQuickConnect.waitForExistence(timeout: 2) {
                altQuickConnect.tap()
                fillConnectionDetails()
                let connectButton = app.buttons["Connect"]
                if connectButton.exists {
                    connectButton.tap()
                }
            }
        }
        
        // Wait for terminal
        let connected = waitForTerminal(timeout: TestConfig.connectionTimeout)
        guard connected else {
            throw XCTSkip("Could not connect to test server")
        }
    }
    
    private func fillConnectionDetails() {
        // Use accessibility identifiers we added to ConnectionListView
        
        // Host field
        let hostField = app.textFields["HostField"]
        if hostField.waitForExistence(timeout: 2) {
            hostField.tap()
            hostField.typeText(TestConfig.sshHost)
        } else {
            logger.warning("HostField not found")
        }
        
        // Username field
        let userField = app.textFields["UsernameField"]
        if userField.waitForExistence(timeout: 1) {
            userField.tap()
            userField.typeText(TestConfig.sshUsername)
        } else {
            logger.warning("UsernameField not found")
        }
        
        // Password field (using password auth)
        if let password = TestConfig.sshPassword {
            let passwordField = app.secureTextFields["PasswordField"]
            if passwordField.waitForExistence(timeout: 1) {
                passwordField.tap()
                passwordField.typeText(password)
            } else {
                logger.warning("PasswordField not found")
            }
        }
        
        // Port field (optional - default is usually 22)
        let portField = app.textFields["PortField"]
        if portField.exists && TestConfig.sshPort != 22 {
            portField.tap()
            portField.typeText(String(TestConfig.sshPort))
        }
    }
    
    private func waitForTerminal(timeout: TimeInterval) -> Bool {
        // Look for terminal indicators
        let terminalSurface = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'TerminalSurface'")).firstMatch
        if terminalSurface.waitForExistence(timeout: timeout) {
            return true
        }
        
        // Also check for absence of connection UI
        let connectionUI = app.buttons["New Connection"]
        return !connectionUI.exists
    }
    
    private func labelAllPanes() {
        // Navigate through panes and type identifiers
        let paneLabels = ["PANE-1", "PANE-2", "PANE-3", "PANE-4"]
        
        for (index, label) in paneLabels.enumerated() {
            app.typeText("echo '\(label)'\n")
            Thread.sleep(forTimeInterval: 0.3)
            
            if index < paneLabels.count - 1 {
                app.typeKey("]", modifierFlags: .command)  // Next pane
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }
    
    private func takeScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        logger.debug("Screenshot: \(name)")
    }
    
    private func logPaneElements() {
        logger.debug("Pane Elements:")
        
        // Find terminal pane elements
        let panes = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'TerminalPane'"))
        logger.debug("   Terminal Panes found: \(panes.count)")
        
        for i in 0..<panes.count {
            let pane = panes.element(boundBy: i)
            logger.debug("   - \(pane.identifier): frame=\(String(describing: pane.frame))")
        }
        
        // Also log surfaces
        let surfaces = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'TerminalSurface'"))
        logger.debug("   Terminal Surfaces found: \(surfaces.count)")
        
        for i in 0..<surfaces.count {
            let surface = surfaces.element(boundBy: i)
            logger.debug("   - \(surface.identifier): frame=\(String(describing: surface.frame))")
        }
    }
}
