//
//  ConfigSyncManager.swift
//  Bodak
//
//  Manages bidirectional sync between GUI settings and Ghostty config file
//

import Foundation
import SwiftUI

/// Manages syncing between GUI preferences (UserDefaults) and ghostty.conf file
class ConfigSyncManager: ObservableObject {
    static let shared = ConfigSyncManager()
    
    private let defaults = UserDefaults.standard
    
    /// Path to config file
    var configFilePath: URL {
        Ghostty.Config.configFilePath
    }
    
    private init() {
        // Initial sync: load config file into GUI if it exists
        loadConfigToGUI()
    }
    
    // MARK: - GUI → Config File
    
    /// Write current GUI settings to config file
    func saveGUIToConfig() {
        let configString = Ghostty.Config.getConfigString()
        
        do {
            try configString.write(to: configFilePath, atomically: true, encoding: .utf8)
            print("[ConfigSync] Saved GUI settings to config file")
        } catch {
            print("[ConfigSync] Failed to save config: \(error)")
        }
    }
    
    // MARK: - Config File → GUI
    
    /// Parse config file and update GUI settings (UserDefaults)
    func loadConfigToGUI() {
        guard FileManager.default.fileExists(atPath: configFilePath.path),
              let content = try? String(contentsOf: configFilePath, encoding: .utf8) else {
            print("[ConfigSync] No config file found, using defaults")
            return
        }
        
        parseConfigAndUpdateGUI(content)
    }
    
    /// Parse config string and update UserDefaults
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
                print("[ConfigSync] Set font-family: \(guiFont)")
                
            case "cursor-style":
                // block, bar, underline
                if ["block", "bar", "underline"].contains(value) {
                    defaults.set(value, forKey: "terminal.cursorStyle")
                    print("[ConfigSync] Set cursor-style: \(value)")
                }
                
            case "font-thicken":
                let boolValue = value == "true"
                defaults.set(boolValue, forKey: "terminal.fontThicken")
                print("[ConfigSync] Set font-thicken: \(boolValue)")
                
            case "theme":
                // Theme name from config
                defaults.set(value, forKey: "terminal.colorTheme")
                // Also update ThemeManager
                if let theme = ThemeManager.shared.themes.first(where: { 
                    $0.name.lowercased() == value.lowercased() ||
                    $0.id.lowercased() == value.lowercased()
                }) {
                    DispatchQueue.main.async {
                        ThemeManager.shared.selectedTheme = theme
                    }
                }
                print("[ConfigSync] Set theme: \(value)")
                
            default:
                // Ignore other config options
                break
            }
        }
        
        print("[ConfigSync] Loaded config file into GUI settings")
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
    
    // MARK: - Bidirectional Sync
    
    /// Call this when GUI settings change to keep config file in sync
    func onGUISettingChanged() {
        saveGUIToConfig()
    }
    
    /// Call this when config file changes to update GUI
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
