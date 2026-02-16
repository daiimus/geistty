//
//  FontMapping.swift
//  Geistty
//
//  Unified font name mapping between GUI display names and Ghostty/CoreText names.
//  This consolidates font definitions that were previously spread across:
//  - Ghostty.swift (mapFontFamily)
//  - ConfigSyncManager.swift (reverseMapFontFamily)
//  - SettingsView.swift (fontFamilies array)
//

import Foundation

/// Centralized font mapping for the app.
/// Maps between user-friendly display names and Ghostty-compatible CoreText names.
public enum FontMapping {
    
    /// All available terminal fonts.
    /// Order determines display order in settings UI.
    /// Note: SF Mono is excluded because it's a system UI font that cannot be
    /// accessed by name via CoreText - it requires special system font APIs.
    public enum Font: String, CaseIterable, Identifiable {
        // Bundled fonts
        case departureMono = "Departure Mono"
        case jetbrainsMono = "JetBrains Mono"
        case firaCode = "Fira Code"
        case hack = "Hack"
        case sourceCodePro = "Source Code Pro"
        case ibmPlexMono = "IBM Plex Mono"
        case inconsolata = "Inconsolata"
        case atkinsonHyperlegibleMono = "Atkinson Hyperlegible Mono"
        
        // System fonts (excludes SF Mono - see note above)
        case menlo = "Menlo"
        case courierNew = "Courier New"
        
        public var id: String { rawValue }
        
        /// Display name for UI
        public var displayName: String { rawValue }
        
        /// CoreText/Ghostty font family name
        public var ghosttyName: String {
            switch self {
            case .departureMono: return "Departure Mono"
            case .jetbrainsMono: return "JetBrains Mono"
            case .firaCode: return "Fira Code"
            case .hack: return "Hack"
            case .sourceCodePro: return "Source Code Pro"
            case .ibmPlexMono: return "IBM Plex Mono"
            case .inconsolata: return "Inconsolata"
            case .atkinsonHyperlegibleMono: return "Atkinson Hyperlegible Mono"
            case .menlo: return "Menlo"
            case .courierNew: return "Courier New"
            }
        }
        
        /// Whether this font is bundled with the app (vs system font)
        public var isBundled: Bool {
            switch self {
            case .departureMono, .jetbrainsMono, .firaCode, .hack,
                 .sourceCodePro, .ibmPlexMono, .inconsolata,
                 .atkinsonHyperlegibleMono:
                return true
            case .menlo, .courierNew:
                return false
            }
        }
        
        /// All possible names that might appear in config files or CoreText
        /// Used for reverse mapping from config → display name
        public var allNames: [String] {
            switch self {
            case .departureMono:
                return ["Departure Mono", "DepartureMono-Regular"]
            case .jetbrainsMono:
                return ["JetBrains Mono", "JetBrainsMono-Regular"]
            case .firaCode:
                return ["Fira Code", "FiraCode-Regular"]
            case .hack:
                return ["Hack", "Hack-Regular"]
            case .sourceCodePro:
                return ["Source Code Pro", "SourceCodePro-Regular"]
            case .ibmPlexMono:
                return ["IBM Plex Mono", "IBMPlexMono", "IBMPlexMono-Regular"]
            case .inconsolata:
                return ["Inconsolata", "Inconsolata-Regular"]
            case .atkinsonHyperlegibleMono:
                return ["Atkinson Hyperlegible Mono", "AtkinsonHyperlegibleMono-Regular"]
            case .menlo:
                return ["Menlo", "Menlo-Regular"]
            case .courierNew:
                return ["Courier New", "CourierNewPSMT"]
            }
        }
    }
    
    // MARK: - Conversion Functions
    
    /// Convert display name to Ghostty config name
    public static func toGhostty(_ displayName: String) -> String {
        if let font = Font(rawValue: displayName) {
            return font.ghosttyName
        }
        return displayName // Pass through unknown fonts
    }
    
    /// Convert Ghostty/CoreText name back to display name
    public static func fromGhostty(_ ghosttyName: String) -> String {
        for font in Font.allCases {
            if font.allNames.contains(ghosttyName) {
                return font.displayName
            }
        }
        return ghosttyName // Pass through unknown fonts
    }
    
    /// All display names for UI picker
    public static var allDisplayNames: [String] {
        Font.allCases.map(\.displayName)
    }
}
