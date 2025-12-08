//
//  SettingsView.swift
//  Bodak
//
//  App settings and preferences
//

import SwiftUI

/// User preferences stored in UserDefaults
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    // MARK: - Terminal Settings
    
    @AppStorage("terminal.colorTheme") var colorTheme: String = "Default"
    @AppStorage("terminal.cursorStyle") var cursorStyle: String = "block"
    @AppStorage("terminal.fontFamily") var fontFamily: String = "SF Mono"
    
    // MARK: - Font Rendering Settings
    
    @AppStorage("terminal.fontThicken") var fontThicken: Bool = true
    @AppStorage("terminal.fontThickenStrength") var fontThickenStrength: Int = 255
    
    // MARK: - UI Settings
    
    @AppStorage("ui.autoHideChrome") var autoHideChrome: Bool = true
    @AppStorage("ui.autoHideDelay") var autoHideDelay: Double = 3.0
    
    private init() {}
    
    // Available color themes (Ghostty themes)
    static let colorThemes = [
        "Default",
        "Dracula",
        "Solarized Dark",
        "Solarized Light",
        "Nord",
        "Gruvbox Dark",
        "One Dark",
        "Tokyo Night"
    ]
    
    // Available monospace fonts on iOS
    // Note: Custom fonts are bundled with the app
    // All fonts below are terminal-focused monospace fonts
    static let fontFamilies = [
        "Departure Mono",    // Bundled - retro pixel style
        "JetBrains Mono",    // Bundled - great ligatures, designed for code
        "Fira Code",         // Bundled - popular with ligatures
        "Hack",              // Bundled - designed for source code
        "Source Code Pro",   // Bundled - Adobe's coding font
        "IBM Plex Mono",     // Bundled - IBM's modern monospace
        "Inconsolata",       // Bundled - humanist monospace
        "SF Mono",           // System - Apple's coding font
        "Menlo",             // System - macOS classic
        "Courier New"        // System - traditional
    ]
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    
    // Font size control - passed from terminal
    var currentFontSize: Int
    var onFontSizeChanged: (Int) -> Void
    var onResetFontSize: () -> Void
    var onFontFamilyChanged: () -> Void
    var onThemeChanged: () -> Void
    
    // Default initializer for preview
    init(
        currentFontSize: Int = 14,
        onFontSizeChanged: @escaping (Int) -> Void = { _ in },
        onResetFontSize: @escaping () -> Void = {},
        onFontFamilyChanged: @escaping () -> Void = {},
        onThemeChanged: @escaping () -> Void = {}
    ) {
        self.currentFontSize = currentFontSize
        self.onFontSizeChanged = onFontSizeChanged
        self.onResetFontSize = onResetFontSize
        self.onFontFamilyChanged = onFontFamilyChanged
        self.onThemeChanged = onThemeChanged
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Color Theme
                Section {
                    NavigationLink {
                        ThemePickerView(onThemeChanged: onThemeChanged)
                    } label: {
                        HStack {
                            Text("Color Theme")
                            Spacer()
                            ThemePreviewStrip(theme: themeManager.selectedTheme)
                                .frame(width: 80)
                        }
                    }
                }
                
                // Cursor Style
                Section {
                    HStack {
                        Text("Cursor")
                        Spacer()
                        Picker("", selection: $settings.cursorStyle) {
                            Text("Block").tag("block")
                            Text("Bar").tag("bar")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                    .disabled(true) // Not yet implemented
                }
                
                // Font Family
                Section {
                    NavigationLink {
                        FontPickerView(
                            selectedFont: $settings.fontFamily,
                            onFontChanged: onFontFamilyChanged
                        )
                    } label: {
                        HStack {
                            Text("Font Family")
                            Spacer()
                            Text(settings.fontFamily)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Font changes apply immediately to the current terminal.")
                }
                
                // Font Size - Live control with slider
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(currentFontSize) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size.smaller")
                                .foregroundStyle(.secondary)
                            
                            Slider(
                                value: Binding(
                                    get: { Double(currentFontSize) },
                                    set: { newValue in
                                        let newSize = Int(newValue.rounded())
                                        if newSize != currentFontSize {
                                            onFontSizeChanged(newSize)
                                        }
                                    }
                                ),
                                in: 8...32,
                                step: 1
                            )
                            
                            Image(systemName: "textformat.size.larger")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    Button("Reset to Default (14 pt)") {
                        onResetFontSize()
                    }
                    .foregroundStyle(.blue)
                }
                
                // Font Rendering - DPI/text quality options
                Section {
                    Toggle("Thicken Font Strokes", isOn: $settings.fontThicken)
                        .onChange(of: settings.fontThicken) { _, _ in
                            onFontFamilyChanged() // Triggers config reload
                        }
                } header: {
                    Text("Text Rendering")
                } footer: {
                    Text("Makes font strokes slightly thicker for improved readability on Retina displays.")
                }
                
                // Interface
                Section("Interface") {
                    Toggle("Auto-hide Header/Toolbar", isOn: $settings.autoHideChrome)
                    
                    if settings.autoHideChrome {
                        HStack {
                            Text("Hide Delay")
                            Spacer()
                            Text("\(settings.autoHideDelay, specifier: "%.1f")s")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.autoHideDelay, in: 1...10, step: 0.5)
                    }
                }
                
                // iCloud Sync
                Section {
                    HStack {
                        Image(systemName: ConnectionProfileManager.shared.iCloudSyncEnabled ? "icloud.fill" : "icloud.slash")
                            .foregroundStyle(ConnectionProfileManager.shared.iCloudSyncEnabled ? .blue : .secondary)
                        Text("iCloud Sync")
                        Spacer()
                        Text(ConnectionProfileManager.shared.iCloudSyncEnabled ? "Enabled" : "Not Available")
                            .foregroundStyle(.secondary)
                    }
                    
                    if ConnectionProfileManager.shared.iCloudSyncEnabled {
                        Button {
                            ConnectionProfileManager.shared.forceiCloudSync()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Sync Now")
                            }
                        }
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    if ConnectionProfileManager.shared.iCloudSyncEnabled {
                        Text("Connection profiles sync automatically across your devices.")
                    } else {
                        Text("Sign in to iCloud in Settings to sync connection profiles across devices.")
                    }
                }
                
                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.2.0")
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("Terminal Engine")
                        Spacer()
                        Text("Ghostty")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Theme Picker

struct ThemePickerView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    var onThemeChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            // Light themes section
            Section("Light Themes") {
                ForEach(themeManager.themes.filter { $0.isLightTheme }) { theme in
                    ThemeRow(
                        theme: theme,
                        isSelected: themeManager.selectedTheme.id == theme.id,
                        onSelect: {
                            themeManager.selectTheme(theme)
                            onThemeChanged()
                        }
                    )
                }
            }
            
            // Dark themes section
            Section("Dark Themes") {
                ForEach(themeManager.themes.filter { !$0.isLightTheme }) { theme in
                    ThemeRow(
                        theme: theme,
                        isSelected: themeManager.selectedTheme.id == theme.id,
                        onSelect: {
                            themeManager.selectTheme(theme)
                            onThemeChanged()
                        }
                    )
                }
            }
        }
        .navigationTitle("Color Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A single row in the theme picker showing theme name and color preview
struct ThemeRow: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Theme name
                VStack(alignment: .leading, spacing: 4) {
                    Text(theme.name)
                        .foregroundStyle(.primary)
                        .font(.body)
                    
                    // Background/foreground indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(theme.background)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
                        Circle()
                            .fill(theme.foreground)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
                    }
                }
                
                Spacer()
                
                // Color palette preview
                ThemePreviewStrip(theme: theme)
                    .frame(width: 100)
                
                // Selection checkmark
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .fontWeight(.semibold)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Horizontal strip showing the 16-color palette
struct ThemePreviewStrip: View {
    let theme: TerminalTheme
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Show colors 0-7 (normal) on top row appearance
                ForEach(0..<8, id: \.self) { index in
                    Rectangle()
                        .fill(theme.palette[index])
                }
            }
            .frame(height: geometry.size.height / 2)
            .overlay(alignment: .bottom) {
                HStack(spacing: 0) {
                    // Show colors 8-15 (bright) on bottom row
                    ForEach(8..<16, id: \.self) { index in
                        Rectangle()
                            .fill(theme.palette[index])
                    }
                }
                .frame(height: geometry.size.height / 2)
            }
        }
        .frame(height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Font Picker

struct FontPickerView: View {
    @Binding var selectedFont: String
    var onFontChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    init(selectedFont: Binding<String>, onFontChanged: @escaping () -> Void = {}) {
        self._selectedFont = selectedFont
        self.onFontChanged = onFontChanged
    }
    
    var body: some View {
        List {
            ForEach(AppSettings.fontFamilies, id: \.self) { font in
                Button {
                    let changed = selectedFont != font
                    if changed {
                        // Update the selection first
                        selectedFont = font
                        // Write directly to UserDefaults to ensure it's persisted
                        // before the config update reads it
                        UserDefaults.standard.set(font, forKey: "terminal.fontFamily")
                        // Call the callback on next run loop to ensure UserDefaults is synced
                        DispatchQueue.main.async {
                            onFontChanged()
                        }
                    }
                    dismiss()
                } label: {
                    HStack {
                        Text(font)
                            .font(.custom(font, size: 17))
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedFont == font {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Font Family")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView(
        currentFontSize: 14,
        onFontSizeChanged: { _ in },
        onResetFontSize: {},
        onFontFamilyChanged: {},
        onThemeChanged: {}
    )
}
