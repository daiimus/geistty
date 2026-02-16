import XCTest
@testable import Geistty

// MARK: - FontMapping Tests

final class FontMappingTests: XCTestCase {

    // MARK: - toGhostty()

    func testToGhosttyDepartureMono() {
        XCTAssertEqual(FontMapping.toGhostty("Departure Mono"), "Departure Mono")
    }

    func testToGhosttyJetBrainsMono() {
        XCTAssertEqual(FontMapping.toGhostty("JetBrains Mono"), "JetBrains Mono")
    }

    func testToGhosttyFiraCode() {
        XCTAssertEqual(FontMapping.toGhostty("Fira Code"), "Fira Code")
    }

    func testToGhosttyHack() {
        XCTAssertEqual(FontMapping.toGhostty("Hack"), "Hack")
    }

    func testToGhosttySourceCodePro() {
        XCTAssertEqual(FontMapping.toGhostty("Source Code Pro"), "Source Code Pro")
    }

    func testToGhosttyIBMPlexMono() {
        XCTAssertEqual(FontMapping.toGhostty("IBM Plex Mono"), "IBM Plex Mono")
    }

    func testToGhosttyInconsolata() {
        XCTAssertEqual(FontMapping.toGhostty("Inconsolata"), "Inconsolata")
    }

    func testToGhosttyAtkinsonHyperlegibleMono() {
        XCTAssertEqual(FontMapping.toGhostty("Atkinson Hyperlegible Mono"), "Atkinson Hyperlegible Mono")
    }

    func testToGhosttyMenlo() {
        XCTAssertEqual(FontMapping.toGhostty("Menlo"), "Menlo")
    }

    func testToGhosstyCourierNew() {
        XCTAssertEqual(FontMapping.toGhostty("Courier New"), "Courier New")
    }

    func testToGhosttyUnknownFontPassthrough() {
        XCTAssertEqual(FontMapping.toGhostty("Monaco"), "Monaco")
        XCTAssertEqual(FontMapping.toGhostty("Comic Sans"), "Comic Sans")
    }

    // MARK: - fromGhostty()

    func testFromGhosttyDepartureMono() {
        XCTAssertEqual(FontMapping.fromGhostty("Departure Mono"), "Departure Mono")
    }

    func testFromGhosttyDepartureMonoRegular() {
        XCTAssertEqual(FontMapping.fromGhostty("DepartureMono-Regular"), "Departure Mono")
    }

    func testFromGhosttyJetBrainsMono() {
        XCTAssertEqual(FontMapping.fromGhostty("JetBrains Mono"), "JetBrains Mono")
    }

    func testFromGhosttyJetBrainsMonoRegular() {
        XCTAssertEqual(FontMapping.fromGhostty("JetBrainsMono-Regular"), "JetBrains Mono")
    }

    func testFromGhosttyFiraCodeRegular() {
        XCTAssertEqual(FontMapping.fromGhostty("FiraCode-Regular"), "Fira Code")
    }

    func testFromGhosttyHackRegular() {
        XCTAssertEqual(FontMapping.fromGhostty("Hack-Regular"), "Hack")
    }

    func testFromGhosttySourceCodeProRegular() {
        XCTAssertEqual(FontMapping.fromGhostty("SourceCodePro-Regular"), "Source Code Pro")
    }

    func testFromGhosttyIBMPlexMonoVariants() {
        XCTAssertEqual(FontMapping.fromGhostty("IBM Plex Mono"), "IBM Plex Mono")
        XCTAssertEqual(FontMapping.fromGhostty("IBMPlexMono"), "IBM Plex Mono")
        XCTAssertEqual(FontMapping.fromGhostty("IBMPlexMono-Regular"), "IBM Plex Mono")
    }

    func testFromGhosttyInconsolataRegular() {
        XCTAssertEqual(FontMapping.fromGhostty("Inconsolata-Regular"), "Inconsolata")
    }

    func testFromGhosttyAtkinsonHyperlegibleMono() {
        XCTAssertEqual(FontMapping.fromGhostty("Atkinson Hyperlegible Mono"), "Atkinson Hyperlegible Mono")
    }

    func testFromGhosttyAtkinsonHyperlegibleMonoRegular() {
        XCTAssertEqual(FontMapping.fromGhostty("AtkinsonHyperlegibleMono-Regular"), "Atkinson Hyperlegible Mono")
    }

    func testFromGhosttyMenloRegular() {
        XCTAssertEqual(FontMapping.fromGhostty("Menlo-Regular"), "Menlo")
    }

    func testFromGhosstyCourierNewPSMT() {
        XCTAssertEqual(FontMapping.fromGhostty("CourierNewPSMT"), "Courier New")
    }

    func testFromGhosttyUnknownFontPassthrough() {
        XCTAssertEqual(FontMapping.fromGhostty("Monaco"), "Monaco")
        XCTAssertEqual(FontMapping.fromGhostty("SomeCustomFont-Bold"), "SomeCustomFont-Bold")
    }

    // MARK: - Round-trip

    func testRoundTripAllFonts() {
        for font in FontMapping.Font.allCases {
            let ghosttyName = FontMapping.toGhostty(font.displayName)
            let backToDisplay = FontMapping.fromGhostty(ghosttyName)
            XCTAssertEqual(backToDisplay, font.displayName,
                           "Round-trip failed for \(font.displayName)")
        }
    }

    func testReverseRoundTripAllAlternateNames() {
        // Every alternate name should map back to the canonical display name,
        // and that display name should map forward to the ghostty name
        for font in FontMapping.Font.allCases {
            for altName in font.allNames {
                let displayName = FontMapping.fromGhostty(altName)
                XCTAssertEqual(displayName, font.displayName,
                               "Alternate name '\(altName)' did not map to '\(font.displayName)'")
            }
        }
    }

    // MARK: - isBundled

    func testBundledFonts() {
        XCTAssertTrue(FontMapping.Font.departureMono.isBundled)
        XCTAssertTrue(FontMapping.Font.jetbrainsMono.isBundled)
        XCTAssertTrue(FontMapping.Font.firaCode.isBundled)
        XCTAssertTrue(FontMapping.Font.hack.isBundled)
        XCTAssertTrue(FontMapping.Font.sourceCodePro.isBundled)
        XCTAssertTrue(FontMapping.Font.ibmPlexMono.isBundled)
        XCTAssertTrue(FontMapping.Font.inconsolata.isBundled)
        XCTAssertTrue(FontMapping.Font.atkinsonHyperlegibleMono.isBundled)
    }

    func testSystemFonts() {
        XCTAssertFalse(FontMapping.Font.menlo.isBundled)
        XCTAssertFalse(FontMapping.Font.courierNew.isBundled)
    }

    // MARK: - allDisplayNames

    func testAllDisplayNamesContainsAllFonts() {
        let names = FontMapping.allDisplayNames
        XCTAssertEqual(names.count, FontMapping.Font.allCases.count)
        for font in FontMapping.Font.allCases {
            XCTAssertTrue(names.contains(font.displayName),
                          "allDisplayNames missing \(font.displayName)")
        }
    }

    func testAllDisplayNamesOrderMatchesCaseIterable() {
        let names = FontMapping.allDisplayNames
        let expected = FontMapping.Font.allCases.map(\.displayName)
        XCTAssertEqual(names, expected)
    }

    // MARK: - Font enum

    func testFontRawValues() {
        XCTAssertEqual(FontMapping.Font.departureMono.rawValue, "Departure Mono")
        XCTAssertEqual(FontMapping.Font.menlo.rawValue, "Menlo")
        XCTAssertEqual(FontMapping.Font.courierNew.rawValue, "Courier New")
    }

    func testFontId() {
        for font in FontMapping.Font.allCases {
            XCTAssertEqual(font.id, font.rawValue)
        }
    }

    func testFontDisplayNameEqualsRawValue() {
        for font in FontMapping.Font.allCases {
            XCTAssertEqual(font.displayName, font.rawValue)
        }
    }
}
