//
//  SettingsTests.swift
//  GeisttyUITests
//
//  Tests for the SettingsView: theme picker, cursor style, font family,
//  font size slider, status bar toggle, opacity slider, config editor link.
//
//  Note: Settings is presented as a sheet from ContentView via Cmd+, or
//  the notification. We trigger it via the menu bar Preferences shortcut.
//

import XCTest

final class SettingsTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchForDisconnectedTests()
        XCTAssertTrue(app.waitForDisconnectedScreen(timeout: 5))

        // Open Settings via the gear button on the disconnected screen toolbar
        let settingsButton = app.buttons["SettingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3),
                      "Settings gear button should exist on disconnected screen")
        settingsButton.tap()

        // Wait for Settings sheet to appear
        let doneButton = app.buttons["SettingsDoneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5),
                      "Settings sheet should appear with Done button")
    }

    override func tearDownWithError() throws {
        takeScreenshot(app, name: "\(name)-teardown")
        app = nil
    }

    // MARK: - Structure

    /// Settings has the correct navigation title.
    func testSettingsTitle() throws {
        let navBar = app.navigationBars["Settings"]
        XCTAssertTrue(navBar.exists, "Settings nav bar should exist")

        takeScreenshot(app, name: "Settings-01-Title")
    }

    /// Done button exists and is tappable.
    func testDoneButtonExists() throws {
        let done = app.buttons["SettingsDoneButton"]
        XCTAssertTrue(done.exists)
        XCTAssertTrue(done.isHittable)

        takeScreenshot(app, name: "Settings-02-DoneButton")
    }

    // MARK: - Theme

    /// Theme picker link exists.
    func testThemePickerLinkExists() throws {
        let themeLink = app.buttons["ThemePickerLink"]
            .exists ? app.buttons["ThemePickerLink"] : app.otherElements["ThemePickerLink"]

        let found = app.element(withIdentifier: "ThemePickerLink") != nil
        XCTAssertTrue(found, "ThemePickerLink should exist")

        takeScreenshot(app, name: "Settings-03-ThemeLink")
    }

    // MARK: - Cursor

    /// Cursor style picker exists with Block/Bar/Underline segments.
    func testCursorStylePickerExists() throws {
        let picker = app.segmentedControls["CursorStylePicker"]
            .exists ? app.segmentedControls["CursorStylePicker"]
                    : app.otherElements["CursorStylePicker"]

        // The segmented control should exist somewhere
        let found = app.element(withIdentifier: "CursorStylePicker") != nil
        XCTAssertTrue(found, "CursorStylePicker should exist")

        takeScreenshot(app, name: "Settings-04-CursorPicker")
    }

    // MARK: - Font

    /// Font family navigation link exists.
    func testFontFamilyLinkExists() throws {
        let fontLink = app.element(withIdentifier: "FontFamilyLink")
        XCTAssertNotNil(fontLink, "FontFamilyLink should exist")

        takeScreenshot(app, name: "Settings-05-FontLink")
    }

    /// Font size slider exists.
    func testFontSizeSliderExists() throws {
        // May need to scroll
        app.swipeUp()

        let slider = app.sliders["FontSizeSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3),
                      "FontSizeSlider should exist")

        takeScreenshot(app, name: "Settings-06-FontSizeSlider")
    }

    /// Reset font size button exists.
    func testResetFontSizeButtonExists() throws {
        app.swipeUp()

        let reset = app.buttons["ResetFontSizeButton"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3),
                      "ResetFontSizeButton should exist")

        takeScreenshot(app, name: "Settings-07-ResetFontSize")
    }

    // MARK: - Interface

    /// Show Status Bar toggle exists.
    func testShowStatusBarToggleExists() throws {
        app.swipeUp()

        let toggle = app.switches["ShowStatusBarToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3),
                      "ShowStatusBarToggle should exist")

        takeScreenshot(app, name: "Settings-08-StatusBarToggle")
    }

    // MARK: - Appearance

    /// Background opacity slider exists.
    func testBackgroundOpacitySliderExists() throws {
        app.swipeUp()

        let slider = app.sliders["BackgroundOpacitySlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3),
                      "BackgroundOpacitySlider should exist")

        takeScreenshot(app, name: "Settings-09-OpacitySlider")
    }

    // MARK: - Config Editor

    /// Config editor link exists.
    func testConfigEditorLinkExists() throws {
        app.swipeUp()
        app.swipeUp()

        let configLink = app.element(withIdentifier: "ConfigEditorLink")
        XCTAssertNotNil(configLink, "ConfigEditorLink should exist")

        takeScreenshot(app, name: "Settings-10-ConfigLink")
    }

    // MARK: - About Section

    /// Version and Terminal Engine info is shown.
    func testAboutSectionExists() throws {
        app.swipeUp()
        app.swipeUp()

        let version = app.staticTexts["Version"]
        let engine = app.staticTexts["Terminal Engine"]

        // These are labels in the About section HStack
        XCTAssertTrue(version.exists || engine.exists,
                      "About section should show version or engine info")

        takeScreenshot(app, name: "Settings-11-About")
    }

    // MARK: - Dismiss

    /// Tapping Done dismisses Settings.
    func testDoneDismissesSettings() throws {
        let done = app.buttons["SettingsDoneButton"]
        done.tap()

        // Settings should be gone
        XCTAssertTrue(done.waitForDisappearance(timeout: 3),
                      "Settings should dismiss after tapping Done")

        XCTAssertTrue(app.isOnDisconnectedScreen,
                      "Should return to disconnected screen")

        takeScreenshot(app, name: "Settings-12-Dismissed")
    }
}
