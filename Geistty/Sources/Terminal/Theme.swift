//
//  Theme.swift
//  Geistty
//
//  Terminal color theme model and parser for Ghostty theme files
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Theme")

/// Represents a terminal color theme parsed from Ghostty theme files
struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    
    // Main colors
    var background: Color
    var foreground: Color
    var cursorColor: Color?
    var cursorText: Color?
    var selectionBackground: Color?
    var selectionForeground: Color?
    
    // 16-color palette (0-7 normal, 8-15 bright)
    var palette: [Color]
    
    /// Raw config string for applying to Ghostty
    var configString: String
    
    /// Check if this is a light theme (background is bright)
    var isLightTheme: Bool {
        // Simple heuristic: if background luminance > 0.5, it's light
        guard let components = UIColor(background).cgColor.components,
              components.count >= 3 else { return false }
        let luminance = 0.299 * components[0] + 0.587 * components[1] + 0.114 * components[2]
        return luminance > 0.5
    }
    
    /// Check if this is a dark theme
    var isDark: Bool {
        !isLightTheme
    }
    
    /// Default dark theme (Ghostty default colors)
    static let `default` = TerminalTheme(
        id: "default",
        name: "Default",
        background: Color(hex: "#282c34"),
        foreground: Color(hex: "#ffffff"),
        cursorColor: Color(hex: "#ffffff"),
        cursorText: nil,
        selectionBackground: nil,
        selectionForeground: nil,
        palette: [
            Color(hex: "#000000"), // 0 - black
            Color(hex: "#cc0000"), // 1 - red
            Color(hex: "#4e9a06"), // 2 - green
            Color(hex: "#c4a000"), // 3 - yellow
            Color(hex: "#3465a4"), // 4 - blue
            Color(hex: "#75507b"), // 5 - magenta
            Color(hex: "#06989a"), // 6 - cyan
            Color(hex: "#d3d7cf"), // 7 - white
            Color(hex: "#555753"), // 8 - bright black
            Color(hex: "#ef2929"), // 9 - bright red
            Color(hex: "#8ae234"), // 10 - bright green
            Color(hex: "#fce94f"), // 11 - bright yellow
            Color(hex: "#729fcf"), // 12 - bright blue
            Color(hex: "#ad7fa8"), // 13 - bright magenta
            Color(hex: "#34e2e2"), // 14 - bright cyan
            Color(hex: "#eeeeec")  // 15 - bright white
        ],
        configString: ""
    )
}

// MARK: - Theme Parser

extension TerminalTheme {
    /// Parse a Ghostty theme file content
    static func parse(name: String, content: String) -> TerminalTheme? {
        var background: Color?
        var foreground: Color?
        var cursorColor: Color?
        var cursorText: Color?
        var selectionBackground: Color?
        var selectionForeground: Color?
        var palette: [Int: Color] = [:]
        
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }
            
            // Parse key = value
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            
            switch key {
            case "background":
                background = Color(hex: value)
            case "foreground":
                foreground = Color(hex: value)
            case "cursor-color":
                cursorColor = Color(hex: value)
            case "cursor-text":
                cursorText = Color(hex: value)
            case "selection-background":
                selectionBackground = Color(hex: value)
            case "selection-foreground":
                selectionForeground = Color(hex: value)
            case "palette":
                // Format: palette = N=#RRGGBB
                let paletteParts = value.split(separator: "=", maxSplits: 1)
                if paletteParts.count == 2,
                   let index = Int(paletteParts[0].trimmingCharacters(in: .whitespaces)),
                   index >= 0 && index < 16 {
                    let colorHex = String(paletteParts[1]).trimmingCharacters(in: .whitespaces)
                    palette[index] = Color(hex: colorHex)
                }
            default:
                break
            }
        }
        
        // Require at least background and foreground
        guard let bg = background, let fg = foreground else {
            return nil
        }
        
        // Build full palette (use defaults for missing)
        var fullPalette: [Color] = TerminalTheme.default.palette
        for (index, color) in palette {
            fullPalette[index] = color
        }
        
        return TerminalTheme(
            id: name.lowercased().replacingOccurrences(of: " ", with: "-"),
            name: name,
            background: bg,
            foreground: fg,
            cursorColor: cursorColor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            palette: fullPalette,
            configString: content
        )
    }
}

// MARK: - Theme Manager

@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    
    @Published private(set) var themes: [TerminalTheme] = []
    @Published var selectedTheme: TerminalTheme = .default
    
    private init() {
        loadBundledThemes()
        
        // Restore selected theme from UserDefaults
        let savedThemeName = UserDefaults.standard.string(forKey: UserDefaultsKey.colorTheme) ?? "Default"
        if let theme = themes.first(where: { $0.name == savedThemeName }) {
            selectedTheme = theme
        }
    }
    
    /// Load all themes from the app bundle
    private func loadBundledThemes() {
        var loadedThemes: [TerminalTheme] = [.default]
        
        // Get themes from bundle
        guard let themesURL = Bundle.main.resourceURL?.appendingPathComponent("themes") else {
            themes = loadedThemes
            return
        }
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: themesURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
            
            for fileURL in fileURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let themeName = fileURL.lastPathComponent
                if let content = try? String(contentsOf: fileURL, encoding: .utf8),
                   let theme = TerminalTheme.parse(name: themeName, content: content) {
                    loadedThemes.append(theme)
                }
            }
        } catch {
            logger.error("Error loading themes: \(error.localizedDescription)")
        }
        
        themes = loadedThemes
    }
    
    /// Select a theme and update config file
    /// Ghostty resolves the theme natively via GHOSTTY_RESOURCES_DIR
    func selectTheme(_ theme: TerminalTheme) {
        selectedTheme = theme
        UserDefaults.standard.set(theme.name, forKey: UserDefaultsKey.colorTheme)
        
        // Write `theme = <name>` to config file and strip old inline colors
        ConfigSyncManager.shared.updateTheme(named: theme.name)
    }
}

// MARK: - Color Extensions

extension Color {
    /// Initialize from hex string like "#RRGGBB" or "RRGGBB"
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        let scanner = Scanner(string: hex)
        let scanned = scanner.scanHexInt64(&int)
        
        let r, g, b: Double
        var a: Double = 1.0
        
        // Validate: scanner must have consumed the full string and hex must be correct length
        guard scanned, scanner.isAtEnd else {
            // Invalid hex — fall back to black
            logger.warning("Invalid hex color string: '\(hex)' — falling back to black")
            self.init(red: 0, green: 0, blue: 0)
            return
        }
        
        switch hex.count {
        case 6: // RGB
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        case 8: // ARGB
            a = Double((int >> 24) & 0xFF) / 255
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            logger.warning("Unexpected hex color length \(hex.count) for '\(hex)' — falling back to black")
            r = 0
            g = 0
            b = 0
        }
        
        self.init(red: r, green: g, blue: b, opacity: a)
    }
    
    /// Convert color to hex string "#RRGGBB"
    var hexString: String {
        guard let components = UIColor(self).cgColor.components else {
            return "#000000"
        }
        
        let r: Int
        let g: Int
        let b: Int
        
        if components.count >= 3 {
            r = Int(components[0] * 255)
            g = Int(components[1] * 255)
            b = Int(components[2] * 255)
        } else {
            // Grayscale
            r = Int(components[0] * 255)
            g = r
            b = r
        }
        
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
