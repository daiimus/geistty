//
//  ConfigSyncManager.swift
//  Bodak
//
//  Manages reading/writing Ghostty config file (source of truth)
//

import Foundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.bodak", category: "ConfigSync")

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
                // Theme name from config - save to UserDefaults first
                defaults.set(value, forKey: "terminal.colorTheme")
                defaults.synchronize()
                logger.debug("Searching for theme: '\\(value)'")
                
                // Find matching theme
                let availableThemes = ThemeManager.shared.themes
                logger.debug("Available themes: \\(availableThemes.map { $0.name })")
                
                if let theme = availableThemes.first(where: { 
                    $0.name.lowercased() == value.lowercased() ||
                    $0.id.lowercased() == value.lowercased()
                }) {
                    logger.info("Found matching theme: \\(theme.name)")
                    DispatchQueue.main.async {
                        ThemeManager.shared.selectedTheme = theme
                        logger.debug("Set ThemeManager.selectedTheme to: \\(theme.name)")
                    }
                } else {
                    logger.warning("⚠️ No matching theme found for: '\\(value)'")
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
        switch ghosttyFont {
        case "Departure Mono", "DepartureMono-Regular":
            return "Departure Mono"
        case "JetBrains Mono", "JetBrainsMono-Regular":
            return "JetBrains Mono"
        case "Fira Code", "FiraCode-Regular":
            return "Fira Code"
        case "Hack", "Hack-Regular":
            return "Hack"
        case "Source Code Pro", "SourceCodePro-Regular":
            return "Source Code Pro"
        case "IBM Plex Mono", "IBMPlexMono", "IBMPlexMono-Regular":
            return "IBM Plex Mono"
        case "Inconsolata", "Inconsolata-Regular":
            return "Inconsolata"
        case "SF Mono", "SFMono-Regular":
            return "SF Mono"
        case "Menlo", "Menlo-Regular":
            return "Menlo"
        case "Courier New", "CourierNewPSMT":
            return "Courier New"
        default:
            return ghosttyFont
        }
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
    
    /// Update theme in config file (writes inline colors)
    func updateTheme(_ theme: TerminalTheme) {
        updateThemeColors(theme)
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
