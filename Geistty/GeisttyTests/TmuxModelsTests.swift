import XCTest
@testable import Geistty

// MARK: - TmuxModels Tests

final class TmuxModelsTests: XCTestCase {

    // MARK: - TmuxSession.parse

    func testParseSessionBasic() {
        let session = TmuxSession.parse("$0 main 3 1")
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.id, "$0")
        XCTAssertEqual(session?.name, "main")
        XCTAssertTrue(session?.isAttached ?? false)
    }

    func testParseSessionDetached() {
        let session = TmuxSession.parse("$1 work 2 0")
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.id, "$1")
        XCTAssertEqual(session?.name, "work")
        XCTAssertFalse(session?.isAttached ?? true)
    }

    func testParseSessionQuotedName() {
        // tmux uses #{q:session_name} which wraps in double quotes for simple names
        // The parser splits on spaces with maxSplits:3, so only names without
        // internal spaces parse correctly. Quoted single-word names have quotes stripped.
        let session = TmuxSession.parse("$2 \"mysession\" 1 0")
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.name, "mysession")
    }

    func testParseSessionTooFewFields() {
        XCTAssertNil(TmuxSession.parse("$0 main"))
        XCTAssertNil(TmuxSession.parse("$0"))
        XCTAssertNil(TmuxSession.parse(""))
    }

    func testParseSessionDefaults() {
        let session = TmuxSession.parse("$5 test 1 0")
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.windowIds, [])
        XCTAssertNil(session?.activeWindowId)
        XCTAssertNil(session?.createdAt)
    }

    // MARK: - TmuxWindow.parse

    func testParseWindowBasic() {
        let window = TmuxWindow.parse("$0 @1 0 bash 1 * d962,80x24,0,0,42")
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.id, "@1")
        XCTAssertEqual(window?.index, 0)
        XCTAssertEqual(window?.name, "bash")
        XCTAssertEqual(window?.sessionId, "$0")
        XCTAssertEqual(window?.flags, "*")
        XCTAssertEqual(window?.layout, "d962,80x24,0,0,42")
    }

    func testParseWindowInactive() {
        let window = TmuxWindow.parse("$0 @2 1 vim 0 - f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}")
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.index, 1)
        XCTAssertEqual(window?.name, "vim")
        XCTAssertEqual(window?.flags, "-")
    }

    func testParseWindowTooFewFields() {
        XCTAssertNil(TmuxWindow.parse("$0 @1 0 bash 1"))
        XCTAssertNil(TmuxWindow.parse("$0 @1"))
        XCTAssertNil(TmuxWindow.parse(""))
    }

    func testParseWindowInvalidIndex() {
        XCTAssertNil(TmuxWindow.parse("$0 @1 abc bash 1 * layout"))
    }

    func testParseWindowDefaults() {
        let window = TmuxWindow.parse("$0 @0 0 shell 0 - layout")
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.paneIds, [])
        XCTAssertNil(window?.activePaneId)
    }

    // MARK: - TmuxPane.parse

    func testParsePaneBasic() {
        let pane = TmuxPane.parse("@0 %1 80 24 1 5 10 0 0")
        XCTAssertNotNil(pane)
        XCTAssertEqual(pane?.id, "%1")
        XCTAssertEqual(pane?.windowId, "@0")
        XCTAssertEqual(pane?.width, 80)
        XCTAssertEqual(pane?.height, 24)
        XCTAssertTrue(pane?.isActive ?? false)
        XCTAssertEqual(pane?.cursorX, 5)
        XCTAssertEqual(pane?.cursorY, 10)
        XCTAssertFalse(pane?.isAlternateScreen ?? true)
        XCTAssertEqual(pane?.mode, .normal)
    }

    func testParsePaneInCopyMode() {
        let pane = TmuxPane.parse("@0 %2 120 40 0 0 0 1 0")
        XCTAssertNotNil(pane)
        XCTAssertEqual(pane?.mode, .copy)
        XCTAssertFalse(pane?.isActive ?? true)
    }

    func testParsePaneAlternateScreen() {
        let pane = TmuxPane.parse("@1 %3 80 24 1 0 0 0 1")
        XCTAssertNotNil(pane)
        XCTAssertTrue(pane?.isAlternateScreen ?? false)
    }

    func testParsePaneTooFewFields() {
        XCTAssertNil(TmuxPane.parse("@0 %1 80 24 1 5 10 0"))
        XCTAssertNil(TmuxPane.parse("@0 %1"))
        XCTAssertNil(TmuxPane.parse(""))
    }

    func testParsePaneInvalidDimensions() {
        XCTAssertNil(TmuxPane.parse("@0 %1 abc def 1 0 0 0 0"))
    }

    func testParsePaneDefaults() {
        let pane = TmuxPane.parse("@0 %0 80 24 0 0 0 0 0")
        XCTAssertNotNil(pane)
        XCTAssertEqual(pane?.positionX, 0)
        XCTAssertEqual(pane?.positionY, 0)
        XCTAssertEqual(pane?.title, "")
        XCTAssertNil(pane?.currentCommand)
    }

    // MARK: - TmuxId Validation

    func testValidSessionId() {
        XCTAssertTrue(TmuxId.isValidSessionId("$0"))
        XCTAssertTrue(TmuxId.isValidSessionId("$123"))
        XCTAssertTrue(TmuxId.isValidSessionId("$999999"))
    }

    func testInvalidSessionId() {
        XCTAssertFalse(TmuxId.isValidSessionId(""))
        XCTAssertFalse(TmuxId.isValidSessionId("$"))
        XCTAssertFalse(TmuxId.isValidSessionId("0"))
        XCTAssertFalse(TmuxId.isValidSessionId("@0"))
        XCTAssertFalse(TmuxId.isValidSessionId("%0"))
        XCTAssertFalse(TmuxId.isValidSessionId("$abc"))
        XCTAssertFalse(TmuxId.isValidSessionId("session"))
    }

    func testValidWindowId() {
        XCTAssertTrue(TmuxId.isValidWindowId("@0"))
        XCTAssertTrue(TmuxId.isValidWindowId("@42"))
        XCTAssertTrue(TmuxId.isValidWindowId("@100"))
    }

    func testInvalidWindowId() {
        XCTAssertFalse(TmuxId.isValidWindowId(""))
        XCTAssertFalse(TmuxId.isValidWindowId("@"))
        XCTAssertFalse(TmuxId.isValidWindowId("0"))
        XCTAssertFalse(TmuxId.isValidWindowId("$0"))
        XCTAssertFalse(TmuxId.isValidWindowId("%0"))
        XCTAssertFalse(TmuxId.isValidWindowId("@abc"))
    }

    func testValidPaneId() {
        XCTAssertTrue(TmuxId.isValidPaneId("%0"))
        XCTAssertTrue(TmuxId.isValidPaneId("%5"))
        XCTAssertTrue(TmuxId.isValidPaneId("%99"))
    }

    func testInvalidPaneId() {
        XCTAssertFalse(TmuxId.isValidPaneId(""))
        XCTAssertFalse(TmuxId.isValidPaneId("%"))
        XCTAssertFalse(TmuxId.isValidPaneId("0"))
        XCTAssertFalse(TmuxId.isValidPaneId("$0"))
        XCTAssertFalse(TmuxId.isValidPaneId("@0"))
        XCTAssertFalse(TmuxId.isValidPaneId("%abc"))
    }

    // MARK: - TmuxId Numeric Extraction

    func testNumericPaneId() {
        XCTAssertEqual(TmuxId.numericPaneId("%0"), 0)
        XCTAssertEqual(TmuxId.numericPaneId("%5"), 5)
        XCTAssertEqual(TmuxId.numericPaneId("%42"), 42)
        XCTAssertNil(TmuxId.numericPaneId("invalid"))
        XCTAssertNil(TmuxId.numericPaneId("%"))
        XCTAssertNil(TmuxId.numericPaneId(""))
    }

    func testNumericWindowId() {
        XCTAssertEqual(TmuxId.numericWindowId("@0"), 0)
        XCTAssertEqual(TmuxId.numericWindowId("@3"), 3)
        XCTAssertEqual(TmuxId.numericWindowId("@100"), 100)
        XCTAssertNil(TmuxId.numericWindowId("invalid"))
        XCTAssertNil(TmuxId.numericWindowId("@"))
    }

    func testNumericSessionId() {
        XCTAssertEqual(TmuxId.numericSessionId("$0"), 0)
        XCTAssertEqual(TmuxId.numericSessionId("$7"), 7)
        XCTAssertEqual(TmuxId.numericSessionId("$256"), 256)
        XCTAssertNil(TmuxId.numericSessionId("invalid"))
        XCTAssertNil(TmuxId.numericSessionId("$"))
    }

    func testPaneIdString() {
        XCTAssertEqual(TmuxId.paneIdString(0), "%0")
        XCTAssertEqual(TmuxId.paneIdString(5), "%5")
        XCTAssertEqual(TmuxId.paneIdString(42), "%42")
    }

    // MARK: - TmuxQueryFormat

    func testQueryFormatStringsAreNonEmpty() {
        XCTAssertFalse(TmuxQueryFormat.sessions.isEmpty)
        XCTAssertFalse(TmuxQueryFormat.windows.isEmpty)
        XCTAssertFalse(TmuxQueryFormat.panes.isEmpty)
    }

    func testQueryFormatSessionsContainsSessionId() {
        XCTAssertTrue(TmuxQueryFormat.sessions.contains("session_id"))
    }

    func testQueryFormatWindowsContainsWindowId() {
        XCTAssertTrue(TmuxQueryFormat.windows.contains("window_id"))
        XCTAssertTrue(TmuxQueryFormat.windows.contains("window_layout"))
    }

    func testQueryFormatPanesContainsPaneId() {
        XCTAssertTrue(TmuxQueryFormat.panes.contains("pane_id"))
        XCTAssertTrue(TmuxQueryFormat.panes.contains("pane_width"))
        XCTAssertTrue(TmuxQueryFormat.panes.contains("pane_height"))
    }

    // MARK: - Model Initialization & Equatable

    func testSessionEquatable() {
        let a = TmuxSession(id: "$0", name: "main")
        let b = TmuxSession(id: "$0", name: "main")
        XCTAssertEqual(a, b)
    }

    func testSessionNotEqual() {
        let a = TmuxSession(id: "$0", name: "main")
        let b = TmuxSession(id: "$1", name: "work")
        XCTAssertNotEqual(a, b)
    }

    func testWindowEquatable() {
        let a = TmuxWindow(id: "@0", index: 0, name: "bash", sessionId: "$0")
        let b = TmuxWindow(id: "@0", index: 0, name: "bash", sessionId: "$0")
        XCTAssertEqual(a, b)
    }

    func testPaneEquatable() {
        let a = TmuxPane(id: "%0", windowId: "@0", width: 80, height: 24)
        let b = TmuxPane(id: "%0", windowId: "@0", width: 80, height: 24)
        XCTAssertEqual(a, b)
    }

    func testPaneNotEqualDifferentDimensions() {
        let a = TmuxPane(id: "%0", windowId: "@0", width: 80, height: 24)
        let b = TmuxPane(id: "%0", windowId: "@0", width: 120, height: 40)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - TmuxId Round-trip

    func testPaneIdRoundTrip() {
        for id in [0, 1, 5, 42, 999] {
            let str = TmuxId.paneIdString(id)
            XCTAssertEqual(TmuxId.numericPaneId(str), id, "Round-trip failed for pane ID \(id)")
        }
    }
}
