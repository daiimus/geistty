//
//  MenuBarTests.swift
//  GeisttyUITests
//
//  Tests for the iPadOS system menu bar — verifies that menu bar items
//  defined via SwiftUI `.commands {}` are queryable by XCUITest on iPad.
//  These tests are diagnostic: they help identify WHY the menu bar may
//  not appear on iPadOS with a hardware keyboard.
//

import XCTest

final class MenuBarTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Menu Bar Existence

    /// Verify that the system menu bar is queryable via XCUITest.
    /// On iPadOS with a hardware keyboard, `app.menuBars` should have at least one element.
    /// On iPhone, the system menu bar does not exist.
    func testMenuBarsExist() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))
        takeScreenshot(app, name: "MenuBar-01-BeforeQuery")

        let menuBarCount = app.menuBars.count
        let menuBarItemCount = app.menuBarItems.count

        // Log diagnostics for the agent
        print("📊 Menu bar count: \(menuBarCount)")
        print("📊 Menu bar items count: \(menuBarItemCount)")

        // Enumerate all menu bar items if any
        for i in 0..<app.menuBarItems.count {
            let item = app.menuBarItems.element(boundBy: i)
            print("📊 Menu bar item \(i): identifier='\(item.identifier)' label='\(item.label)' exists=\(item.exists)")
        }

        takeScreenshot(app, name: "MenuBar-02-AfterQuery")
    }

    /// Query all menu bar items by known names from our `.commands {}` definition.
    func testExpectedMenuItemsExist() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // SwiftUI `.commands {}` defines these menus:
        // - App menu (Geistty): Preferences
        // - File: New Connection, Quick Connect, Close Connection
        // - Edit: Copy, Paste, Select All, Find submenu
        // - View: Increase/Decrease/Reset Font Size, Command Palette
        // - Terminal (custom): Clear Screen, Reset Terminal, etc.
        // - Connection (custom): Connection Profiles, SSH Key Manager
        // - Help: Keyboard Shortcuts

        let expectedMenus = ["File", "Edit", "View", "Terminal", "Connection", "Help"]

        for menuName in expectedMenus {
            let menuItem = app.menuBarItems[menuName]
            print("📊 Menu '\(menuName)': exists=\(menuItem.exists)")
        }

        // Try to access menu bar by tapping — on iPad, Cmd+blank can show menu
        // Or we can query the menu items directly
        let fileMenu = app.menuBarItems["File"]
        if fileMenu.exists {
            print("📊 File menu found! Tapping to enumerate children...")
            fileMenu.tap()
            Thread.sleep(forTimeInterval: 0.5)

            let menuItems = app.menuItems
            for i in 0..<menuItems.count {
                let item = menuItems.element(boundBy: i)
                print("📊 File menu item \(i): '\(item.label)'")
            }

            takeScreenshot(app, name: "MenuBar-03-FileMenuOpen")
        }
    }

    /// Verify keyboard shortcuts work even without visible menu bar.
    /// This tests that the NotificationCenter-based approach works.
    func testKeyboardShortcutsCmdN() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // Cmd+N should open connection list (New Connection)
        app.typeKey("n", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "MenuBar-04-AfterCmdN")

        // Should show connection list
        let connectionList = app.navigationBars["Saved Connections"]
        let hasConnectionList = connectionList.waitForExistence(timeout: 3)
        print("📊 After Cmd+N: connection list visible = \(hasConnectionList)")
    }

    /// Verify Cmd+Shift+N opens Quick Connect.
    func testKeyboardShortcutsCmdShiftN() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // Cmd+Shift+N should open Quick Connect
        app.typeKey("n", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "MenuBar-05-AfterCmdShiftN")

        // Should show quick connect sheet
        let newConnection = app.navigationBars["New Connection"]
        let hasQuickConnect = newConnection.waitForExistence(timeout: 3)
        print("📊 After Cmd+Shift+N: quick connect visible = \(hasQuickConnect)")
    }

    /// Verify Cmd+, opens Settings.
    func testKeyboardShortcutsCmdComma() throws {
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // Cmd+, should open Settings
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)

        takeScreenshot(app, name: "MenuBar-06-AfterCmdComma")

        // Look for settings-related UI
        let settingsNav = app.navigationBars["Settings"]
        let hasSettings = settingsNav.waitForExistence(timeout: 3)
        print("📊 After Cmd+,: settings visible = \(hasSettings)")
    }
}
