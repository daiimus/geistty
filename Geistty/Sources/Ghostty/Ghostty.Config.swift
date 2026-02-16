//
//  Ghostty.Config.swift
//  Geistty
//
//  Configuration wrapper for ghostty_config_t
//  Extracted from Ghostty.swift — follows upstream Ghostty macOS naming convention
//

import Foundation
import UIKit
import GhosttyKit

// MARK: - Ghostty.Config

extension Ghostty {
    /// Configuration wrapper for ghostty_config_t
    class Config {
        private(set) var config: ghostty_config_t
        
        /// Path to the Ghostty config file in the app's documents directory
        static var configFilePath: URL {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documentsPath.appendingPathComponent("ghostty.conf")
        }
        
        // MARK: - Config Introspection via ghostty_config_get()
        // Follows upstream macOS Ghostty pattern: each property calls
        // ghostty_config_get() with a typed pointer. The Zig side dispatches
        // on the pointer type to return the correct value.
        
        /// Background color from finalized config
        var backgroundColor: UIColor {
            var color: ghostty_config_color_s = .init()
            let key = "background"
            if (!ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8)))) {
                return UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
            }
            return UIColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1.0
            )
        }
        
        /// Foreground color from finalized config
        var foregroundColor: UIColor {
            var color: ghostty_config_color_s = .init()
            let key = "foreground"
            if (!ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8)))) {
                return UIColor.white
            }
            return UIColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1.0
            )
        }
        
        // NOTE: font-family is a RepeatableString in Ghostty's Zig config.
        // ghostty_config_get() has no handler for this type (c_get.zig returns false).
        // Font family must be read from the config file directly.
        // See: Config.zig line 5679 (RepeatableString), c_get.zig line 67-85 (struct dispatch)
        
        /// Cursor style from finalized config (block, bar, underline)
        var cursorStyle: String {
            var v: UnsafePointer<Int8>? = nil
            let key = "cursor-style"
            guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return "block" }
            guard let ptr = v else { return "block" }
            return String(cString: ptr)
        }
        
        /// Font thicken setting from finalized config
        var fontThicken: Bool {
            var v = true
            let key = "font-thicken"
            _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
            return v
        }
        
        /// Background opacity from finalized config
        var backgroundOpacity: Double {
            var v: Double = 1
            let key = "background-opacity"
            _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
            return v
        }
        
        /// Command palette entries from Ghostty config.
        /// Returns ~70+ default commands; callers should filter with `.isSupported`.
        var commandPaletteEntries: [Ghostty.Command] {
            var v: ghostty_config_command_list_s = .init()
            let key = "command-palette-entry"
            guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return [] }
            guard v.len > 0 else { return [] }
            let buffer = UnsafeBufferPointer(start: v.commands, count: v.len)
            return buffer.map { Ghostty.Command(cValue: $0) }
        }
        
        // NOTE: theme is a ?Theme struct (light/dark pair) in Ghostty's Zig config.
        // ghostty_config_get() has no handler for Theme (no cval(), not packed).
        // Theme name must be read from the config file directly.
        // See: Config.zig line 9373 (Theme struct), c_get.zig line 67-85 (struct dispatch)
        
        init?() {
            // Ghostty runtime must be initialized before creating configs
            guard App.isInitialized else {
                logger.warning("Config.init skipped: Ghostty runtime not initialized")
                return nil
            }
            
            guard let cfg = ghostty_config_new() else {
                logger.error("ghostty_config_new returned nil")
                return nil
            }
            config = cfg
            
            // Load config from file (source of truth)
            // getConfigString() creates default file if needed
            let configStr = Self.getConfigString()
            configStr.withCString { cstr in
                ghostty_config_load_string(cfg, cstr, UInt(configStr.utf8.count))
                logger.info("Loaded config from file into Ghostty")
            }
            
            ghostty_config_finalize(config)
        }
        
        /// Get config string - FILE IS SOURCE OF TRUTH
        /// If ghostty.conf exists, read from it; otherwise generate defaults
        static func getConfigString() -> String {
            // Check if config file exists and read from it
            if FileManager.default.fileExists(atPath: configFilePath.path),
               let content = try? String(contentsOf: configFilePath, encoding: .utf8) {
                logger.info("📖 Reading config from file: \(configFilePath.path)")
                
                // Migration: Fix scrollback-limit = 0 or too small (breaks scrolling)
                // Old versions used 0 which disables all scrollback
                // Unit is BYTES, not lines! 50000000 = 50MB
                // H4 fix: use line-based matching to handle \r\n, EOF without newline,
                // and avoid false-matching "10000" inside "10000000"
                let needsMigration = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).contains { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed == "scrollback-limit = 0" ||
                           trimmed == "scrollback-limit = 10000" ||
                           trimmed == "scrollback-limit = 10000000"
                }
                
                if needsMigration {
                    logger.info("🔧 Migrating config: fixing scrollback-limit → 50000000 (50MB)")
                    // Replace line-by-line to preserve line endings
                    let lines = content.components(separatedBy: .newlines)
                    let migratedLines = lines.map { line -> String in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed == "scrollback-limit = 0" ||
                           trimmed == "scrollback-limit = 10000" ||
                           trimmed == "scrollback-limit = 10000000" {
                            return "scrollback-limit = 50000000"
                        }
                        return line
                    }
                    let migratedContent = migratedLines.joined(separator: "\n")
                    
                    // Save the migrated config
                    do {
                        try migratedContent.write(to: configFilePath, atomically: true, encoding: .utf8)
                        logger.info("✅ Config migrated successfully")
                    } catch {
                        logger.error("Failed to save migrated config: \(error)")
                    }
                    return migratedContent
                }
                
                return content
            }
            
            // No file exists, generate default config and save it
            logger.info("📝 No config file found, creating with defaults")
            let defaultConfig = generateDefaultConfig()
            
            // Save the default config to file so user can edit it
            do {
                try defaultConfig.write(to: configFilePath, atomically: true, encoding: .utf8)
                logger.info("📝 Created default config file at: \(configFilePath.path)")
            } catch {
                logger.error("Failed to write default config: \(error)")
            }
            
            return defaultConfig
        }
        
        /// Generate a default config string (used when no file exists)
        /// This is a static template - no dependencies on ThemeManager or UserDefaults
        static func generateDefaultConfig() -> String {
            return """
            # Geistty Terminal Configuration
            # This file is the source of truth - edit directly
            # Reload with Cmd+Shift+, or from Settings
            
            # === Font Settings ===
            # Note: SF Mono is not available via CoreText - use Menlo or bundled fonts
            font-family = "Menlo"
            font-thicken = true
            
            # Freetype hinting for clarity
            freetype-load-flags = hinting, autohint, light
            
            # Unicode standard for emoji/CJK widths
            grapheme-width-method = unicode
            
            # === Cursor ===
            cursor-style = block
            cursor-style-blink = true
            
            # === Colors ===
            # Ghostty resolves themes natively from the bundle's themes/ directory
            # Uncomment to use a theme: theme = Dracula+
            background-opacity = 0.95
            bold-color = bright
            
            # === Input ===
            # Treat Option key as Alt for vim/emacs/tmux keybindings
            # (Alt+b/f for word nav, Alt+. for last arg, etc.)
            macos-option-as-alt = true
            
            # === Terminal Behavior ===
            window-padding-x = 4
            window-padding-y = 4
            scrollback-limit = 50000000
            
            # URL detection
            link-url = true
            
            # === Clipboard ===
            clipboard-read = allow
            clipboard-write = allow
            copy-on-select = false
            
            # === Graphics (for TUI apps like Yazi) ===
            image-storage-limit = 500000000
            """
        }
        
        /// Create a new config with the current user preferences
        /// Returns nil if config creation fails
        static func createConfigWithCurrentSettings() -> ghostty_config_t? {
            guard let cfg = ghostty_config_new() else {
                logger.error("Failed to create new config")
                return nil
            }
            
            // Get config string and load it directly
            let configStr = getConfigString()
            configStr.withCString { cstr in
                ghostty_config_load_string(cfg, cstr, UInt(configStr.utf8.count))
                logger.info("Loaded config string with font settings")
            }
            
            ghostty_config_finalize(cfg)
            return cfg
        }
        
        deinit {
            ghostty_config_free(config)
        }
    }
}
