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
    
    @AppStorage("terminal.fontSize") var fontSize: Double = 14
    @AppStorage("terminal.fontFamily") var fontFamily: String = "Departure Mono"
    @AppStorage("terminal.cursorStyle") var cursorStyle: String = "block"
    @AppStorage("terminal.cursorBlink") var cursorBlink: Bool = true
    
    // MARK: - UI Settings
    
    @AppStorage("ui.autoHideChrome") var autoHideChrome: Bool = true
    @AppStorage("ui.autoHideDelay") var autoHideDelay: Double = 3.0
    @AppStorage("ui.hapticFeedback") var hapticFeedback: Bool = true
    
    // MARK: - SSH Settings
    
    @AppStorage("ssh.keepAliveInterval") var keepAliveInterval: Int = 30
    @AppStorage("ssh.connectionTimeout") var connectionTimeout: Int = 10
    @AppStorage("ssh.compressionEnabled") var compressionEnabled: Bool = false
    
    // MARK: - Security Settings
    
    @AppStorage("security.requireBiometric") var requireBiometric: Bool = false
    @AppStorage("security.lockOnBackground") var lockOnBackground: Bool = false
    
    private init() {}
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    
    var body: some View {
        NavigationStack {
            Form {
                // Terminal Section
                Section("Terminal") {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(settings.fontSize)) pt")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.fontSize, in: 10...24, step: 1)
                    
                    Picker("Font", selection: $settings.fontFamily) {
                        Text("Departure Mono").tag("Departure Mono")
                        Text("JetBrains Mono").tag("JetBrains Mono")
                        Text("SF Mono").tag("SF Mono")
                        Text("Menlo").tag("Menlo")
                        Text("Monaco").tag("Monaco")
                        Text("Courier New").tag("Courier New")
                    }
                    
                    Picker("Cursor Style", selection: $settings.cursorStyle) {
                        Text("Block").tag("block")
                        Text("Underline").tag("underline")
                        Text("Bar").tag("bar")
                    }
                    
                    Toggle("Cursor Blink", isOn: $settings.cursorBlink)
                }
                
                // UI Section
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
                    
                    Toggle("Haptic Feedback", isOn: $settings.hapticFeedback)
                }
                
                // SSH Section
                Section("SSH") {
                    Stepper("Keep-Alive: \(settings.keepAliveInterval)s", value: $settings.keepAliveInterval, in: 0...120, step: 10)
                    
                    Stepper("Connection Timeout: \(settings.connectionTimeout)s", value: $settings.connectionTimeout, in: 5...60, step: 5)
                    
                    Toggle("Compression", isOn: $settings.compressionEnabled)
                }
                
                // Security Section
                Section("Security") {
                    Toggle("Require Face ID / Touch ID", isOn: $settings.requireBiometric)
                    Toggle("Lock When Backgrounded", isOn: $settings.lockOnBackground)
                }
                
                // About Section
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    
                    Link(destination: URL(string: "https://github.com/ghostty-org/ghostty")!) {
                        HStack {
                            Text("Ghostty on GitHub")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Link(destination: URL(string: "https://ghostty.org")!) {
                        HStack {
                            Text("Ghostty Website")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
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

#Preview {
    SettingsView()
}
