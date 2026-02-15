//
//  ConfigSyncManager.swift
//  Geistty
//
//  Manages reading/writing Ghostty config file (source of truth)
//

import Foundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "ConfigSync")

/// Manages the Ghostty config file (source of truth)
class ConfigSyncManager: ObservableObject {
    static let shared = ConfigSyncManager()
    
    private let defaults = UserDefaults.standard
    
    /// Path to config file
    var configFilePath: URL {
        Ghostty.Config.configFilePath
    }
    
    private init() {
        // Initial sync: load config file values into GUI display
        loadConfigToGUI()
    }
    
    // MARK: - Update Config File
    
    /// Update a single key in the config file (file is source of truth)
    func updateConfigValue(key: String, value: String) {
        // Read current config
        var content = (try? String(contentsOf: configFilePath, encoding: .utf8)) ?? ""
        
        // Find and replace the key, or append if not found
        let lines = content.components(separatedBy: "\n")
        var found = false
        var updatedLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip comments - keep them as-is
            if trimmed.hasPrefix("#") || trimmed.isEmpty {
                updatedLines.append(line)
                continue
            }
            
            // Check if this line is for our key
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let lineKey = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
                if lineKey == key {
                    // Replace this line with new value
                    let needsQuotes = value.contains(" ") || key == "font-family"
                    let formattedValue = needsQuotes ? "\"\(value)\"" : value
                    updatedLines.append("\(key) = \(formattedValue)")
                    found = true
                    continue
                }
            }
            
            updatedLines.append(line)
        }
        
        // If key wasn't found, append it
        if !found {
            let needsQuotes = value.contains(" ") || key == "font-family"
            let formattedValue = needsQuotes ? "\"\(value)\"" : value
            updatedLines.append("\(key) = \(formattedValue)")
        }
        
        // Write back to file
        content = updatedLines.joined(separator: "\n")
        do {
            try content.write(to: configFilePath, atomically: true, encoding: .utf8)
            logger.info("Updated \(key) = \(value) in config file")
        } catch {
            logger.error("Failed to update config: \(error.localizedDescription)")
        }
    }
    
    /// Update theme colors in config file
    /// Writes `theme = <name>` — Ghostty resolves the theme file natively
    /// via GHOSTTY_RESOURCES_DIR pointing at our bundle. Also removes any old
    /// inline color entries that were injected by the previous theme system.
    /// When "Default" is selected, removes the theme line entirely so Ghostty
    /// uses its built-in defaults.
    func updateTheme(_ themeName: String) {
        // Read current config
        let content = (try? String(contentsOf: configFilePath, encoding: .utf8)) ?? ""
        
        // Transform config
        let updated = Self.applyTheme(themeName, to: content)
        
        // Write back to file
        do {
            try updated.write(to: configFilePath, atomically: true, encoding: .utf8)
            logger.info("Updated theme to: \(themeName)")
        } catch {
            logger.error("Failed to update theme: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Pure Transformations (testable)
    
    /// Color keys that the old theme system injected inline.
    /// Used by `applyTheme` to strip them so Ghostty's native theme resolution
    /// has a clean slate.
    static let inlineColorKeys = Set([
        "background", "foreground", "cursor-color", "cursor-text",
        "selection-background", "selection-foreground", "palette"
    ])
    
    /// Pure function: transform a config string to apply a theme.
    /// - Strips old inline color entries (`palette`, `background`, etc.)
    /// - Strips old `# Theme:` comment lines
    /// - Replaces or appends `theme = <name>` (or removes it for "Default")
    /// - Preserves all other config lines unchanged
    static func applyTheme(_ themeName: String, to configString: String) -> String {
        let isDefault = themeName == "Default"
        let lines = configString.components(separatedBy: "\n")
        var updatedLines: [String] = []
        var foundThemeLine = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip old theme comment lines (e.g., "# Theme: Dracula+")
            if trimmed.hasPrefix("# Theme:") {
                continue
            }
            
            // Keep other comments and empty lines
            if trimmed.hasPrefix("#") || trimmed.isEmpty {
                updatedLines.append(line)
                continue
            }
            
            // Check if this is an inline color key to remove
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let lineKey = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
                if inlineColorKeys.contains(lineKey) {
                    // Skip old inline color entries
                    continue
                }
                if lineKey == "theme" {
                    if isDefault {
                        // Default = no theme line, use Ghostty built-in colors
                    } else {
                        updatedLines.append("theme = \(themeName)")
                    }
                    foundThemeLine = true
                    continue
                }
            }
            
            updatedLines.append(line)
        }
        
        // If no theme line existed and not using default, append it
        if !foundThemeLine && !isDefault {
            updatedLines.append("theme = \(themeName)")
        }
        
        return updatedLines.joined(separator: "\n")
    }
    
    // MARK: - Config File → GUI
    
    /// Parse config file and update GUI settings (UserDefaults) for display
    func loadConfigToGUI() {
        guard FileManager.default.fileExists(atPath: configFilePath.path),
              let content = try? String(contentsOf: configFilePath, encoding: .utf8) else {
            logger.info("No config file found, using defaults")
            return
        }
        
        parseConfigAndUpdateGUI(content)
    }
    
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
                // Sync theme name to ThemeManager for UI display (theme picker selection)
                defaults.set(value, forKey: "terminal.colorTheme")
                defaults.synchronize()
                
                // Update ThemeManager's selected theme for UI preview
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
                // Ignore other config options
                break
            }
        }
        
        logger.info("Loaded config file into GUI settings")
    }
    
    /// Reverse map Ghostty font family to GUI display name
    private func reverseMapFontFamily(_ ghosttyFont: String) -> String {
        // Implementation now in FontMapping.swift
        FontMapping.fromGhostty(ghosttyFont)
    }
    
    // MARK: - GUI Setting Updates (writes to config file)
    
    /// Update font family in config file
    func updateFontFamily(_ fontFamily: String) {
        let ghosttyFont = Ghostty.Config.mapFontFamily(fontFamily)
        updateConfigValue(key: "font-family", value: ghosttyFont)
    }
    
    /// Update cursor style in config file
    func updateCursorStyle(_ style: String) {
        updateConfigValue(key: "cursor-style", value: style)
    }
    
    /// Update font thicken in config file
    func updateFontThicken(_ enabled: Bool) {
        updateConfigValue(key: "font-thicken", value: enabled ? "true" : "false")
    }
    
    /// Update theme in config file — writes `theme = <name>` and strips old inline colors
    func updateTheme(named themeName: String) {
        updateTheme(themeName)
    }
    
    /// Update background opacity in config file
    func updateBackgroundOpacity(_ opacity: Double) {
        updateConfigValue(key: "background-opacity", value: String(format: "%.2f", opacity))
    }
    
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
    
    /// Called when config file is edited externally - reload GUI
    func onConfigFileChanged() {
        loadConfigToGUI()
        // Notify UI to refresh
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .configFileUpdated, object: nil)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let configFileUpdated = Notification.Name("configFileUpdated")
}
