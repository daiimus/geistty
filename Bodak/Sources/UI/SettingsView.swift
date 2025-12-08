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
    static let fontFamilies = [
        "SF Mono",
        "Menlo",
        "Courier New",
        "Monaco"
    ]
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    
    // Font size control - passed from terminal
    var currentFontSize: Int
    var onIncreaseFontSize: () -> Void
    var onDecreaseFontSize: () -> Void
    var onResetFontSize: () -> Void
    
    // Default initializer for preview
    init(
        currentFontSize: Int = 14,
        onIncreaseFontSize: @escaping () -> Void = {},
        onDecreaseFontSize: @escaping () -> Void = {},
        onResetFontSize: @escaping () -> Void = {}
    ) {
        self.currentFontSize = currentFontSize
        self.onIncreaseFontSize = onIncreaseFontSize
        self.onDecreaseFontSize = onDecreaseFontSize
        self.onResetFontSize = onResetFontSize
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Color Theme
                Section {
                    NavigationLink {
                        ThemePickerView(selectedTheme: $settings.colorTheme)
                    } label: {
                        HStack {
                            Text("Color Theme")
                            Spacer()
                            Text(settings.colorTheme)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(true) // Not yet implemented
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
                        FontPickerView(selectedFont: $settings.fontFamily)
                    } label: {
                        HStack {
                            Text("Font Family")
                            Spacer()
                            Text(settings.fontFamily)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(true) // Not yet implemented
                }
                
                // Font Size - Live control!
                Section {
                    HStack {
                        Text("Font Size: \(currentFontSize)")
                        Spacer()
                        
                        HStack(spacing: 0) {
                            Button {
                                onDecreaseFontSize()
                            } label: {
                                Image(systemName: "minus")
                                    .frame(width: 44, height: 36)
                            }
                            .buttonStyle(.bordered)
                            
                            Divider()
                                .frame(height: 20)
                            
                            Button {
                                onIncreaseFontSize()
                            } label: {
                                Image(systemName: "plus")
                                    .frame(width: 44, height: 36)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    Button("Reset to Default") {
                        onResetFontSize()
                    }
                    .foregroundStyle(.blue)
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
                
                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
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
    @Binding var selectedTheme: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            ForEach(AppSettings.colorThemes, id: \.self) { theme in
                Button {
                    selectedTheme = theme
                    dismiss()
                } label: {
                    HStack {
                        Text(theme)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedTheme == theme {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Color Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Font Picker

struct FontPickerView: View {
    @Binding var selectedFont: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            ForEach(AppSettings.fontFamilies, id: \.self) { font in
                Button {
                    selectedFont = font
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
    SettingsView()
}
