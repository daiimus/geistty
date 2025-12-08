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
    
    // MARK: - UI Settings (Functional)
    
    @AppStorage("ui.autoHideChrome") var autoHideChrome: Bool = true
    @AppStorage("ui.autoHideDelay") var autoHideDelay: Double = 3.0
    
    // MARK: - Placeholder Settings (Not yet wired up)
    // These are stored but not yet connected to Ghostty
    // TODO: Wire these up when Ghostty config API supports runtime changes
    
    @AppStorage("terminal.fontSize") var fontSize: Double = 14
    @AppStorage("ssh.keepAliveInterval") var keepAliveInterval: Int = 30
    @AppStorage("ssh.connectionTimeout") var connectionTimeout: Int = 10
    
    private init() {}
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    
    var body: some View {
        NavigationStack {
            Form {
                // UI Section - These settings are functional
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
                
                // Font Size Info
                Section {
                    HStack {
                        Image(systemName: "hand.pinch")
                            .foregroundStyle(.secondary)
                        Text("Pinch to zoom to change font size")
                    }
                    HStack {
                        Image(systemName: "hand.tap")
                            .foregroundStyle(.secondary)
                        Text("Two-finger double-tap to reset")
                    }
                } header: {
                    Text("Font Size")
                } footer: {
                    Text("Or use A+ / A- buttons in the toolbar")
                }
                
                // About Section
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
