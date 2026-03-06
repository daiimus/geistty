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
@MainActor
class ConfigSyncManager: ObservableObject {
    static let shared = ConfigSyncManager()
    
    /// Default background opacity when not specified in config
    private static let defaultBackgroundOpacity: Double = 0.95
    
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
    
    /// Detect line ending style used in a config string.
    /// Returns `"\r\n"` if CRLF is found, otherwise `"\n"`.
    private static func detectLineEnding(in content: String) -> String {
        content.contains("\r\n") ? "\r\n" : "\n"
    }
    
    /// Update a single key in the config file (file is source of truth)
    func updateConfigValue(key: String, value: String) {
        // Read current config
        var content = (try? String(contentsOf: configFilePath, encoding: .utf8)) ?? ""
        
        // Detect and preserve original line ending style
        let lineEnding = Self.detectLineEnding(in: content)
        
        // Find and replace the key, or append if not found
        let lines = content.components(separatedBy: lineEnding)
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
                    if !found {
                        // Replace the first occurrence with the new value
                        let needsQuotes = value.contains(" ") || key == "font-family"
                        let formattedValue = needsQuotes ? "\"\(value)\"" : value
                        updatedLines.append("\(key) = \(formattedValue)")
                        found = true
                    }
                    // Drop subsequent duplicates of the same key
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
        content = updatedLines.joined(separator: lineEnding)
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
        let lineEnding = detectLineEnding(in: configString)
        let lines = configString.components(separatedBy: lineEnding)
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
        
        return updatedLines.joined(separator: lineEnding)
    }
    
    // MARK: - Config → GUI Sync
    
    /// Sync GUI settings from a finalized Ghostty.Config object.
    /// Uses `ghostty_config_get()` to read the authoritative values
    /// after Ghostty's config finalization (theme resolution, defaults, etc.).
    ///
    /// Only syncs fields that `ghostty_config_get()` supports (simple types).
    /// Complex types (font-family → RepeatableString, theme → Theme struct)
    /// must be read from the config file — see `loadConfigToGUI()`.
    func syncFromConfig(_ config: Ghostty.Config) {
        // Cursor style
        let cursor = config.cursorStyle
        if ["block", "bar", "underline"].contains(cursor) {
            defaults.set(cursor, forKey: UserDefaultsKey.cursorStyle)
            logger.debug("Synced cursor-style: \(cursor)")
        }
        
        // Font thicken
        defaults.set(config.fontThicken, forKey: UserDefaultsKey.fontThicken)
        logger.debug("Synced font-thicken: \(config.fontThicken)")
        
        // Background opacity
        defaults.set(config.backgroundOpacity, forKey: UserDefaultsKey.backgroundOpacity)
        logger.debug("Synced background-opacity: \(config.backgroundOpacity)")
        
        logger.info("Synced supported config fields via ghostty_config_get()")
    }
    
    /// Load config and sync to GUI settings (UserDefaults).
    ///
    /// Hybrid approach:
    /// 1. If Ghostty runtime is available, create a Config and use
    ///    `ghostty_config_get()` for supported simple types (cursor-style,
    ///    font-thicken, background-opacity).
    /// 2. ALWAYS parse the config file for fields that `ghostty_config_get()`
    ///    cannot read: font-family (RepeatableString) and theme (?Theme struct).
    /// 3. If Ghostty runtime is NOT available (early startup), fall back to
    ///    file parsing for ALL fields.
    func loadConfigToGUI() {
        // Try the Config-based path for supported fields
        if let config = Ghostty.Config() {
            syncFromConfig(config)
        }
        
        // Always parse the file for fields ghostty_config_get() can't handle
        // (font-family, theme) — and as full fallback if Config wasn't available
        guard FileManager.default.fileExists(atPath: configFilePath.path) else {
            logger.info("No config file found at \(configFilePath.path), using defaults")
            return
        }
        
        guard let content = try? String(contentsOf: configFilePath, encoding: .utf8) else {
            logger.error("Failed to read config file at \(configFilePath.path)")
            return
        }
        
        parseConfigFileForGUI(content)
    }
    
    /// Parse config file line-by-line to populate GUI defaults.
    ///
    /// This is the ONLY path for font-family (RepeatableString) and theme
    /// (?Theme struct), which `ghostty_config_get()` cannot read.
    /// Also serves as the full fallback before Ghostty runtime is initialized.
    private func parseConfigFileForGUI(_ configString: String) {
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
                let guiFont = FontMapping.fromGhostty(value)
                defaults.set(guiFont, forKey: UserDefaultsKey.fontFamily)
                logger.debug("File parser: font-family = \(guiFont)")
                
            // cursor-style, font-thicken, background-opacity are handled by
            // syncFromConfig() via ghostty_config_get() API — no file parsing needed.
                
            case "theme":
                defaults.set(value, forKey: UserDefaultsKey.colorTheme)
                logger.debug("File parser: theme = \(value)")
                let availableThemes = ThemeManager.shared.themes
                if let theme = availableThemes.first(where: {
                    $0.name.lowercased() == value.lowercased() ||
                    $0.id.lowercased() == value.lowercased()
                }) {
                    ThemeManager.shared.selectedTheme = theme
                }
                
            default:
                break
            }
        }
        
        logger.info("Parsed config file for GUI settings")
    }
    
    // MARK: - GUI Setting Updates (writes to config file)
    
    /// Update font family in config file
    func updateFontFamily(_ fontFamily: String) {
        let ghosttyFont = FontMapping.toGhostty(fontFamily)
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
    
    /// Get current background opacity.
    /// Reads from a finalized Ghostty.Config (preferred) or falls back to
    /// parsing the config file directly.
    func getBackgroundOpacity() -> Double {
        // Preferred: read from Ghostty's finalized config
        if let config = Ghostty.Config() {
            return config.backgroundOpacity
        }
        
        // Fallback: parse the file
        guard FileManager.default.fileExists(atPath: configFilePath.path),
              let content = try? String(contentsOf: configFilePath, encoding: .utf8) else {
            return Self.defaultBackgroundOpacity
        }
        
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            
            let key = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            if key == "background-opacity" {
                let value = String(trimmed[trimmed.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
                return Double(value) ?? Self.defaultBackgroundOpacity
            }
        }
        return Self.defaultBackgroundOpacity
    }
    
    /// Called when config file is edited externally - reload GUI
    func onConfigFileChanged() {
        loadConfigToGUI()
    }
}
