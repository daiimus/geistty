//
//  UITestHelpers.swift
//  GeisttyUITests
//
//  Shared helpers for all UI tests: screenshot capture, element waits,
//  accessibility-identifier queries, connection utilities, and visual
//  regression testing via screenshot comparison.
//

import os
import XCTest
import CoreGraphics
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.geistty.uitests", category: "Helpers")

// MARK: - Screenshot Helpers

extension XCTestCase {

    /// Capture a screenshot and attach it to the test results.
    /// The attachment is kept forever so the agent can inspect xcresult bundles.
    func takeScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        logger.debug("Screenshot: \(name)")
    }

    /// Capture the full device screenshot (not just the app window).
    func takeDeviceScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        logger.debug("Device screenshot: \(name)")
    }
}

// MARK: - Screenshot Comparison (Visual Regression Testing)

/// Result of comparing two screenshots.
struct ScreenshotComparisonResult {
    /// Percentage of pixels that differ (0.0 = identical, 100.0 = completely different).
    let diffPercentage: Double
    /// Total number of pixels compared.
    let totalPixels: Int
    /// Number of pixels that differed beyond the per-pixel threshold.
    let differentPixels: Int
    /// Whether the comparison passed the tolerance check.
    let passed: Bool
    /// The tolerance that was used for the comparison.
    let tolerance: Double
}

extension XCTestCase {

    /// Directory where reference screenshots are stored, relative to the UI test bundle.
    /// When recording, screenshots are saved here. When comparing, they're loaded from here.
    private static var referenceScreenshotsDir: URL {
        // Use the project source directory for reference screenshots so they can be
        // git-tracked. The UI test bundle is compiled into DerivedData which is ephemeral.
        // Resolve path relative to this source file's location.
        let sourceFile = URL(fileURLWithPath: #filePath)
        let helpersDir = sourceFile.deletingLastPathComponent()
        let uiTestsDir = helpersDir.deletingLastPathComponent()
        return uiTestsDir.appendingPathComponent("ReferenceScreenshots", isDirectory: true)
    }

    /// Whether we are in record mode (saving new baselines instead of comparing).
    /// Set via `RECORD_SNAPSHOTS=1` environment variable or `--record-snapshots` launch arg.
    private var isRecordMode: Bool {
        ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
    }

    /// Device-specific subdirectory name for reference screenshots.
    /// Includes device model and scale factor for deterministic matching.
    private var deviceSubdirectory: String {
        let device = UIDevice.current
        let screen = UIScreen.main
        let model = device.name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let scale = Int(screen.scale)
        return "\(model)_\(scale)x"
    }

    /// Assert that the current app screenshot matches the stored reference image.
    ///
    /// On first run (no reference exists), saves the screenshot as the new baseline.
    /// In record mode (`RECORD_SNAPSHOTS=1`), always saves and passes.
    ///
    /// - Parameters:
    ///   - app: The XCUIApplication to screenshot.
    ///   - name: Unique name for this screenshot (e.g., "Launch-01-InitialState").
    ///   - tolerance: Maximum allowed pixel difference percentage (default 1.0%).
    ///   - perPixelThreshold: Per-channel difference threshold (0-255) below which pixels
    ///     are considered matching. Handles anti-aliasing. Default 10.
    ///   - excludeStatusBar: If true, crops out the top 54pt (status bar area) to avoid
    ///     clock/battery changes causing false failures. Default true.
    ///   - file: Source file for failure reporting.
    ///   - line: Source line for failure reporting.
    func assertScreenshotMatches(
        _ app: XCUIApplication,
        name: String,
        tolerance: Double = 1.0,
        perPixelThreshold: UInt8 = 10,
        excludeStatusBar: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let screenshot = app.screenshot()
        let image = screenshot.image

        // Always attach the actual screenshot for inspection
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "actual-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let currentCG = image.cgImage else {
            XCTFail("Failed to get CGImage from screenshot", file: file, line: line)
            return
        }

        let refDir = Self.referenceScreenshotsDir
            .appendingPathComponent(deviceSubdirectory, isDirectory: true)
        let refPath = refDir.appendingPathComponent("\(name).png")

        // Record mode or first run: save baseline
        if isRecordMode || !FileManager.default.fileExists(atPath: refPath.path) {
            saveReferenceImage(currentCG, to: refPath, file: file, line: line)
            if isRecordMode {
                logger.info("📸 Recorded reference: \(name)")
            } else {
                logger.info("📸 No reference found, saved baseline: \(name)")
                // Don't fail on first run — the baseline is now established
            }
            return
        }

        // Load reference image
        guard let refData = try? Data(contentsOf: refPath),
              let refDataProvider = CGDataProvider(data: refData as CFData),
              let refCG = CGImage(pngDataProviderSource: refDataProvider,
                                 decode: nil, shouldInterpolate: false,
                                 intent: .defaultIntent) else {
            XCTFail("Failed to load reference image at \(refPath.path)", file: file, line: line)
            return
        }

        // Compare
        let result = compareImages(
            actual: currentCG,
            reference: refCG,
            perPixelThreshold: perPixelThreshold,
            tolerance: tolerance,
            excludeStatusBar: excludeStatusBar,
            screenScale: image.scale
        )

        if !result.passed {
            // Attach diff details
            let message = """
                Screenshot '\(name)' differs from reference by \
                \(String(format: "%.2f", result.diffPercentage))% \
                (\(result.differentPixels)/\(result.totalPixels) pixels). \
                Tolerance: \(tolerance)%
                """
            logger.error("❌ \(message)")

            // Generate and attach a diff image for visual debugging
            if let diffImage = generateDiffImage(actual: currentCG, reference: refCG,
                                                  perPixelThreshold: perPixelThreshold,
                                                  excludeStatusBar: excludeStatusBar,
                                                  screenScale: image.scale) {
                let diffAttachment = XCTAttachment(image: UIImage(cgImage: diffImage))
                diffAttachment.name = "diff-\(name)"
                diffAttachment.lifetime = .keepAlways
                add(diffAttachment)
            }

            // Also attach the reference for side-by-side comparison
            let refAttachment = XCTAttachment(image: UIImage(cgImage: refCG))
            refAttachment.name = "reference-\(name)"
            refAttachment.lifetime = .keepAlways
            add(refAttachment)

            XCTFail(message, file: file, line: line)
        } else {
            logger.debug("✅ Screenshot matches: \(name) (\(String(format: "%.3f", result.diffPercentage))% diff)")
        }
    }

    /// Compare two screenshots taken at different points and assert they are visually identical.
    /// Useful for testing that an interaction does NOT change the UI (e.g., layout stability).
    ///
    /// - Parameters:
    ///   - before: Screenshot taken before the interaction.
    ///   - after: Screenshot taken after the interaction.
    ///   - name: Name for attachments.
    ///   - tolerance: Maximum allowed pixel difference percentage.
    ///   - excludeStatusBar: Crop out the status bar area.
    ///   - file: Source file for failure reporting.
    ///   - line: Source line for failure reporting.
    func assertScreenshotsMatch(
        before: XCUIScreenshot,
        after: XCUIScreenshot,
        name: String,
        tolerance: Double = 0.5,
        excludeStatusBar: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let beforeCG = before.image.cgImage,
              let afterCG = after.image.cgImage else {
            XCTFail("Failed to get CGImage from screenshots", file: file, line: line)
            return
        }

        // Attach both for inspection
        let beforeAtt = XCTAttachment(screenshot: before)
        beforeAtt.name = "before-\(name)"
        beforeAtt.lifetime = .keepAlways
        add(beforeAtt)

        let afterAtt = XCTAttachment(screenshot: after)
        afterAtt.name = "after-\(name)"
        afterAtt.lifetime = .keepAlways
        add(afterAtt)

        let result = compareImages(
            actual: afterCG,
            reference: beforeCG,
            perPixelThreshold: 10,
            tolerance: tolerance,
            excludeStatusBar: excludeStatusBar,
            screenScale: before.image.scale
        )

        if !result.passed {
            let message = """
                Screenshots '\(name)' before/after differ by \
                \(String(format: "%.2f", result.diffPercentage))% \
                (\(result.differentPixels)/\(result.totalPixels) pixels). \
                Tolerance: \(tolerance)%
                """

            if let diffImage = generateDiffImage(actual: afterCG, reference: beforeCG,
                                                  perPixelThreshold: 10,
                                                  excludeStatusBar: excludeStatusBar,
                                                  screenScale: before.image.scale) {
                let diffAtt = XCTAttachment(image: UIImage(cgImage: diffImage))
                diffAtt.name = "diff-\(name)"
                diffAtt.lifetime = .keepAlways
                add(diffAtt)
            }

            XCTFail(message, file: file, line: line)
        } else {
            logger.debug("✅ Before/after match: \(name) (\(String(format: "%.3f", result.diffPercentage))% diff)")
        }
    }

    // MARK: - Private Comparison Engine

    /// Pixel-by-pixel comparison of two CGImages.
    private func compareImages(
        actual: CGImage,
        reference: CGImage,
        perPixelThreshold: UInt8,
        tolerance: Double,
        excludeStatusBar: Bool,
        screenScale: CGFloat
    ) -> ScreenshotComparisonResult {
        let width = min(actual.width, reference.width)
        let height = min(actual.height, reference.height)

        // Status bar crop: 54pt at the top (in pixels = 54 * scale)
        let statusBarPixels = excludeStatusBar ? Int(54.0 * screenScale) : 0
        let compareStartY = statusBarPixels
        let compareHeight = height - statusBarPixels

        guard compareHeight > 0, width > 0 else {
            return ScreenshotComparisonResult(
                diffPercentage: 100.0, totalPixels: 0, differentPixels: 0,
                passed: false, tolerance: tolerance
            )
        }

        // Render both images into raw RGBA byte arrays for comparison
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        guard let actualData = renderToRGBA(actual, width: width, height: height),
              let refData = renderToRGBA(reference, width: width, height: height) else {
            return ScreenshotComparisonResult(
                diffPercentage: 100.0, totalPixels: 0, differentPixels: 0,
                passed: false, tolerance: tolerance
            )
        }

        var differentPixels = 0
        let totalPixels = width * compareHeight
        let threshold = Int(perPixelThreshold)

        for y in compareStartY..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                guard offset + 3 < totalBytes else { continue }

                let rDiff = abs(Int(actualData[offset]) - Int(refData[offset]))
                let gDiff = abs(Int(actualData[offset + 1]) - Int(refData[offset + 1]))
                let bDiff = abs(Int(actualData[offset + 2]) - Int(refData[offset + 2]))

                // A pixel differs if ANY channel exceeds the threshold
                if rDiff > threshold || gDiff > threshold || bDiff > threshold {
                    differentPixels += 1
                }
            }
        }

        let diffPercentage = totalPixels > 0
            ? (Double(differentPixels) / Double(totalPixels)) * 100.0
            : 0.0
        let passed = diffPercentage <= tolerance

        return ScreenshotComparisonResult(
            diffPercentage: diffPercentage,
            totalPixels: totalPixels,
            differentPixels: differentPixels,
            passed: passed,
            tolerance: tolerance
        )
    }

    /// Render a CGImage to a raw RGBA byte array.
    private func renderToRGBA(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    /// Generate a visual diff image highlighting differing pixels in red.
    private func generateDiffImage(
        actual: CGImage,
        reference: CGImage,
        perPixelThreshold: UInt8,
        excludeStatusBar: Bool,
        screenScale: CGFloat
    ) -> CGImage? {
        let width = min(actual.width, reference.width)
        let height = min(actual.height, reference.height)
        let statusBarPixels = excludeStatusBar ? Int(54.0 * screenScale) : 0

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        guard let actualData = renderToRGBA(actual, width: width, height: height),
              let refData = renderToRGBA(reference, width: width, height: height) else {
            return nil
        }

        // Start with a dimmed version of the actual image
        var diffData = [UInt8](repeating: 0, count: height * bytesPerRow)
        let threshold = Int(perPixelThreshold)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                guard offset + 3 < diffData.count else { continue }

                if y < statusBarPixels {
                    // Gray out status bar area
                    diffData[offset] = 128
                    diffData[offset + 1] = 128
                    diffData[offset + 2] = 128
                    diffData[offset + 3] = 255
                    continue
                }

                let rDiff = abs(Int(actualData[offset]) - Int(refData[offset]))
                let gDiff = abs(Int(actualData[offset + 1]) - Int(refData[offset + 1]))
                let bDiff = abs(Int(actualData[offset + 2]) - Int(refData[offset + 2]))

                if rDiff > threshold || gDiff > threshold || bDiff > threshold {
                    // Highlight differing pixels in bright red
                    diffData[offset] = 255
                    diffData[offset + 1] = 0
                    diffData[offset + 2] = 0
                    diffData[offset + 3] = 255
                } else {
                    // Dim matching pixels (30% opacity of actual)
                    diffData[offset] = UInt8(Int(actualData[offset]) * 30 / 100)
                    diffData[offset + 1] = UInt8(Int(actualData[offset + 1]) * 30 / 100)
                    diffData[offset + 2] = UInt8(Int(actualData[offset + 2]) * 30 / 100)
                    diffData[offset + 3] = 255
                }
            }
        }

        // Create CGImage from diff data
        guard let context = CGContext(
            data: &diffData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        return context.makeImage()
    }

    /// Save a CGImage as PNG to the reference directory.
    private func saveReferenceImage(_ image: CGImage, to url: URL,
                                    file: StaticString, line: UInt) {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create reference directory: \(error)", file: file, line: line)
            return
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            XCTFail("Failed to create PNG destination at \(url.path)", file: file, line: line)
            return
        }

        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            XCTFail("Failed to write reference PNG to \(url.path)", file: file, line: line)
        }
    }
}

// MARK: - Element Wait Helpers

extension XCUIElement {

    /// Wait for the element to exist, then return it. Returns `nil` on timeout.
    @discardableResult
    func waitForExistenceAndReturn(timeout: TimeInterval = 5) -> XCUIElement? {
        guard waitForExistence(timeout: timeout) else { return nil }
        return self
    }

    /// Wait for the element to become hittable (visible and interactable).
    func waitUntilHittable(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    /// Wait for the element to disappear.
    func waitForDisappearance(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}

// MARK: - Accessibility-Identifier Queries

extension XCUIApplication {

    /// Find an element by accessibility identifier across common element types.
    /// Checks buttons, text fields, secure text fields, static texts, other elements,
    /// switches, sliders, and links — in that order.
    func element(withIdentifier id: String) -> XCUIElement? {
        let queries: [XCUIElementQuery] = [
            buttons,
            textFields,
            secureTextFields,
            staticTexts,
            otherElements,
            switches,
            sliders,
            links,
            searchFields,
            segmentedControls,
        ]
        for query in queries {
            let el = query[id]
            if el.exists { return el }
        }
        return nil
    }

    /// Find all elements whose accessibility identifier starts with the given prefix.
    /// Searches `otherElements` by default; pass a specific query for narrower scope.
    func elements(withIdentifierPrefix prefix: String,
                  in query: XCUIElementQuery? = nil) -> [XCUIElement] {
        let target = query ?? otherElements
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        let matches = target.matching(predicate)
        return (0..<matches.count).map { matches.element(boundBy: $0) }
    }

    /// Count elements whose identifier matches a prefix (useful for pane/surface counts).
    func countElements(withIdentifierPrefix prefix: String,
                       in query: XCUIElementQuery? = nil) -> Int {
        let target = query ?? otherElements
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        return target.matching(predicate).count
    }
}

// MARK: - Terminal Detection

extension XCUIApplication {

    /// Returns `true` if any `TerminalSurface-*` element exists.
    var isInTerminalView: Bool {
        let surfaces = otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'TerminalSurface'")
        )
        return surfaces.count > 0
    }

    /// Returns `true` if we are on the disconnected/connection screen.
    var isOnDisconnectedScreen: Bool {
        // Check for the disconnected title or quick-connect button
        return staticTexts["DisconnectedTitle"].exists
            || buttons["DisconnectedQuickConnectButton"].exists
    }

    /// Returns `true` if we are showing the error view.
    var isOnErrorScreen: Bool {
        return staticTexts["ErrorTitle"].exists
    }

    /// Wait until the terminal surface appears (connection succeeded).
    func waitForTerminal(timeout: TimeInterval = 30) -> Bool {
        let surface = otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH 'TerminalSurface'")
        ).firstMatch
        return surface.waitForExistence(timeout: timeout)
    }

    /// Wait until the disconnected screen appears.
    func waitForDisconnectedScreen(timeout: TimeInterval = 10) -> Bool {
        return staticTexts["DisconnectedTitle"].waitForExistence(timeout: timeout)
            || buttons["DisconnectedQuickConnectButton"].waitForExistence(timeout: timeout)
    }
}

// MARK: - Pane & Surface Helpers

extension XCUIApplication {

    /// Count visible terminal panes (TerminalPane-* identifiers).
    var terminalPaneCount: Int {
        countElements(withIdentifierPrefix: "TerminalPane")
    }

    /// Count visible terminal surfaces (TerminalSurface-* identifiers).
    var terminalSurfaceCount: Int {
        countElements(withIdentifierPrefix: "TerminalSurface")
    }
}

// MARK: - UI Hierarchy Logging

extension XCTestCase {

    /// Dump identifiable UI elements to the log for debugging.
    func logVisibleElements(_ app: XCUIApplication, label: String = "UI Hierarchy") {
        logger.debug("\(label):")
        logger.debug("  Windows: \(app.windows.count)")

        let elementTypes: [(String, XCUIElementQuery)] = [
            ("Buttons", app.buttons),
            ("TextFields", app.textFields),
            ("SecureTextFields", app.secureTextFields),
            ("StaticTexts", app.staticTexts),
            ("Switches", app.switches),
            ("Sliders", app.sliders),
            ("OtherElements", app.otherElements),
        ]

        for (typeName, query) in elementTypes {
            let identified = query.allElementsBoundByIndex.filter { !$0.identifier.isEmpty }
            if !identified.isEmpty {
                logger.debug("  \(typeName):")
                for el in identified {
                    logger.debug("    - \(el.identifier): frame=\(String(describing: el.frame))")
                }
            }
        }
    }
}

// MARK: - Connection Helpers

extension XCTestCase {

    /// Launch the app configured for disconnected-state testing (no auto-connect).
    func launchForDisconnectedTests() -> XCUIApplication {
        let app = XCUIApplication()
        // Do NOT pass --ui-testing so the app stays on the disconnected screen
        app.launch()
        return app
    }

    /// Launch the app configured for connected-state testing using TestConfig.
    /// Passes `--ui-testing` with `--test-host/port/user/key` arguments.
    func launchForConnectedTests() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--test-host", TestConfig.sshHost,
            "--test-port", String(TestConfig.sshPort),
            "--test-user", TestConfig.sshUsername,
            "--test-key", TestConfig.keyFilePath,
        ]
        app.launch()
        return app
    }
}

// MARK: - Keyboard Shortcut Helpers

extension XCUIApplication {

    /// Send Cmd+D (horizontal split).
    func splitHorizontal() {
        typeKey("d", modifierFlags: .command)
    }

    /// Send Cmd+Shift+D (vertical split).
    func splitVertical() {
        typeKey("d", modifierFlags: [.command, .shift])
    }

    /// Send Cmd+] (next pane).
    func focusNextPane() {
        typeKey("]", modifierFlags: .command)
    }

    /// Send Cmd+[ (previous pane).
    func focusPreviousPane() {
        typeKey("[", modifierFlags: .command)
    }

    /// Send Cmd+F (open search).
    func openSearch() {
        typeKey("f", modifierFlags: .command)
    }

    /// Send Cmd+Shift+P (command palette).
    func openCommandPalette() {
        typeKey("p", modifierFlags: [.command, .shift])
    }

    /// Send Cmd+W (close pane/window).
    func closeCurrentPane() {
        typeKey("w", modifierFlags: .command)
    }

    /// Send Cmd+T (new tab/window).
    func newWindow() {
        typeKey("t", modifierFlags: .command)
    }

    /// Send Cmd++ (increase font size).
    func increaseFontSize() {
        typeKey("+", modifierFlags: .command)
    }

    /// Send Cmd+- (decrease font size).
    func decreaseFontSize() {
        typeKey("-", modifierFlags: .command)
    }

    /// Send Cmd+0 (reset font size).
    func resetFontSize() {
        typeKey("0", modifierFlags: .command)
    }

    /// Send Cmd+Shift+[ (previous tab/window).
    func previousWindow() {
        typeKey("[", modifierFlags: [.command, .shift])
    }

    /// Send Cmd+Shift+] (next tab/window).
    func nextWindow() {
        typeKey("]", modifierFlags: [.command, .shift])
    }
}
