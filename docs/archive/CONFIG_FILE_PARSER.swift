// CONFIG_FILE_PARSER.swift
// Archived: Session 5 (Config introspection via ghostty_config_get)
//
// This code was the original ConfigSyncManager.parseConfigAndUpdateGUI() method
// and getBackgroundOpacity() method that parsed the ghostty.conf file line-by-line
// in Swift to extract config values for the GUI.
//
// Replaced by: ghostty_config_get() computed properties on Ghostty.Config,
// which read directly from Ghostty's finalized config object. This eliminates
// the need for a Swift-side config parser and ensures we always read the
// authoritative values (after theme resolution, default application, etc.).
//
// The legacy file parser is still present in ConfigSyncManager as a private
// fallback for early startup before ghostty_init() is called, but the primary
// path now uses syncFromConfig().

// --- Original parseConfigAndUpdateGUI (public, ~70 lines) ---

/// Parse config string and update UserDefaults for GUI display
func parseConfigAndUpdateGUI(_ configString: String) {
    let lines = configString.components(separatedBy: "\n")
    
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        // Skip comments and empty lines
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        
        // Parse key = value
        guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
        
        let key = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        var value = String(trimmed[trimmed.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
        
        // Remove quotes from value if present
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        
        // Map config keys to UserDefaults
        switch key {
        case "font-family":
            // Reverse map Ghostty font name to GUI font name
            let guiFont = reverseMapFontFamily(value)
            defaults.set(guiFont, forKey: "terminal.fontFamily")
            defaults.synchronize()
            logger.debug("Set font-family: \(guiFont)")
            
        case "cursor-style":
            // block, bar, underline
            if ["block", "bar", "underline"].contains(value) {
                defaults.set(value, forKey: "terminal.cursorStyle")
                defaults.synchronize()
                logger.debug("Set cursor-style: \(value)")
            }
            
        case "font-thicken":
            let boolValue = value == "true"
            defaults.set(boolValue, forKey: "terminal.fontThicken")
            defaults.synchronize()
            logger.debug("Set font-thicken: \(boolValue)")
            
        case "theme":
            defaults.set(value, forKey: "terminal.colorTheme")
            defaults.synchronize()
            
            let availableThemes = ThemeManager.shared.themes
            if let theme = availableThemes.first(where: { 
                $0.name.lowercased() == value.lowercased() ||
                $0.id.lowercased() == value.lowercased()
            }) {
                DispatchQueue.main.async {
                    ThemeManager.shared.selectedTheme = theme
                }
            }
            
        default:
            break
        }
    }
    
    logger.info("Loaded config file into GUI settings")
}

/// Reverse map Ghostty font family to GUI display name
private func reverseMapFontFamily(_ ghosttyFont: String) -> String {
    FontMapping.fromGhostty(ghosttyFont)
}

// --- Original getBackgroundOpacity (~20 lines) ---

/// Get current background opacity from config (default 0.95)
func getBackgroundOpacity() -> Double {
    guard FileManager.default.fileExists(atPath: configFilePath.path),
          let content = try? String(contentsOf: configFilePath, encoding: .utf8) else {
        return 0.95
    }
    
    let lines = content.components(separatedBy: "\n")
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
        
        let key = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        if key == "background-opacity" {
            let value = String(trimmed[trimmed.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
            return Double(value) ?? 0.95
        }
    }
    return 0.95
}

// --- Original backgroundColor on Ghostty.Config ---

/// Background color from config (default to dark)
var backgroundColor: UIColor {
    // TODO: Read from actual config once we parse it
    return UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
}
