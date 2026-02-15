// ARCHIVED: February 2026 — Theme inline color injection system
//
// These functions were part of the old theme system where Geistty parsed
// Ghostty theme files in Swift, converted them to SwiftUI Colors, then
// injected inline `palette = N=#RRGGBB` entries directly into ghostty.conf.
//
// Replaced by native Ghostty theme resolution:
//   - Set GHOSTTY_RESOURCES_DIR to Bundle.main.bundlePath
//   - Write `theme = <name>` to ghostty.conf
//   - Ghostty's Zig engine resolves themes via <resources_dir>/themes/
//
// See: src/config/Config.zig loadTheme(), src/config/theme.zig

// ============================================================
// FROM: Sources/Terminal/Theme.swift — ThemeManager
// ============================================================

/// Get the Ghostty config string for the selected theme
/// Generated inline palette + color entries from parsed Swift Color objects
func getThemeConfigString() -> String {
    var config = ""
    
    // Add palette entries
    for (index, color) in selectedTheme.palette.enumerated() {
        config += "palette = \(index)=\(color.hexString)\n"
    }
    
    // Add main colors
    config += "background = \(selectedTheme.background.hexString)\n"
    config += "foreground = \(selectedTheme.foreground.hexString)\n"
    
    if let cursor = selectedTheme.cursorColor {
        config += "cursor-color = \(cursor.hexString)\n"
    }
    if let cursorText = selectedTheme.cursorText {
        config += "cursor-text = \(cursorText.hexString)\n"
    }
    if let selBg = selectedTheme.selectionBackground {
        config += "selection-background = \(selBg.hexString)\n"
    }
    if let selFg = selectedTheme.selectionForeground {
        config += "selection-foreground = \(selFg.hexString)\n"
    }
    
    return config
}

// ============================================================
// FROM: Sources/Ghostty/ConfigSyncManager.swift
// ============================================================

/// Update theme colors in config file (removes old colors, adds new ones)
/// Theme colors are inline because iOS doesn't have Ghostty's theme directory
func updateThemeColors(_ theme: TerminalTheme) {
    // Read current config
    var content = (try? String(contentsOf: configFilePath, encoding: .utf8)) ?? ""
    
    // Color keys to remove/replace
    let colorKeys = Set(["background", "foreground", "cursor-color", "cursor-text",
                         "selection-background", "selection-foreground", "palette", "theme"])
    
    // Filter out existing color lines and theme comments
    let lines = content.components(separatedBy: "\n")
    var updatedLines: [String] = []
    
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        // Skip old theme comment lines
        if trimmed.hasPrefix("# Theme:") {
            continue
        }
        
        // Keep other comments and empty lines
        if trimmed.hasPrefix("#") || trimmed.isEmpty {
            updatedLines.append(line)
            continue
        }
        
        // Check if this is a color key we're replacing
        if let equalsIndex = trimmed.firstIndex(of: "=") {
            let lineKey = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            if colorKeys.contains(lineKey) {
                // Skip this line - we'll add new colors at the end
                continue
            }
        }
        
        updatedLines.append(line)
    }
    
    // Remove trailing empty lines before adding theme section
    while let last = updatedLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        updatedLines.removeLast()
    }
    
    // Add theme comment and colors
    updatedLines.append("")
    updatedLines.append("# Theme: \(theme.name)")
    
    // Add palette
    for (index, color) in theme.palette.enumerated() {
        updatedLines.append("palette = \(index)=\(color.hexString)")
    }
    
    // Add main colors
    updatedLines.append("background = \(theme.background.hexString)")
    updatedLines.append("foreground = \(theme.foreground.hexString)")
    
    if let cursor = theme.cursorColor {
        updatedLines.append("cursor-color = \(cursor.hexString)")
    }
    if let cursorText = theme.cursorText {
        updatedLines.append("cursor-text = \(cursorText.hexString)")
    }
    if let selBg = theme.selectionBackground {
        updatedLines.append("selection-background = \(selBg.hexString)")
    }
    if let selFg = theme.selectionForeground {
        updatedLines.append("selection-foreground = \(selFg.hexString)")
    }
    
    // Write back to file
    content = updatedLines.joined(separator: "\n")
    do {
        try content.write(to: configFilePath, atomically: true, encoding: .utf8)
        logger.info("Updated theme to: \(theme.name)")
    } catch {
        logger.error("Failed to update theme: \(error.localizedDescription)")
    }
}

/// Old wrapper that took a TerminalTheme object
func updateTheme(_ theme: TerminalTheme) {
    updateThemeColors(theme)
}
