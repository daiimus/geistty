//
//  SettingsView.swift
//  Geistty
//
//  App settings and preferences
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.geistty", category: "Settings")

/// User preferences stored in UserDefaults
///
/// Uses @Published + UserDefaults.didSet instead of @AppStorage,
/// which is designed for View structs, not ObservableObject classes.
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard
    
    // MARK: - Terminal Settings
    
    @Published var cursorStyle: String {
        didSet { defaults.set(cursorStyle, forKey: UserDefaultsKey.cursorStyle) }
    }
    @Published var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: UserDefaultsKey.fontFamily) }
    }
    
    // MARK: - Font Rendering Settings
    
    @Published var fontThicken: Bool {
        didSet { defaults.set(fontThicken, forKey: UserDefaultsKey.fontThicken) }
    }

    
    // MARK: - Appearance Settings
    
    @Published var backgroundOpacity: Double {
        didSet { defaults.set(backgroundOpacity, forKey: UserDefaultsKey.backgroundOpacity) }
    }
    
    // MARK: - UI Settings
    
    @Published var showStatusBar: Bool {
        didSet { defaults.set(showStatusBar, forKey: UserDefaultsKey.showStatusBar) }
    }
    
    private init() {
        // Initialize from UserDefaults with fallback defaults.
        // Assignments in init don't trigger didSet, so no spurious writes.
        cursorStyle = defaults.string(forKey: UserDefaultsKey.cursorStyle) ?? "block"
        fontFamily = defaults.string(forKey: UserDefaultsKey.fontFamily) ?? "Menlo"
        fontThicken = defaults.object(forKey: UserDefaultsKey.fontThicken) as? Bool ?? true
        backgroundOpacity = defaults.object(forKey: UserDefaultsKey.backgroundOpacity) as? Double ?? 0.95
        showStatusBar = defaults.object(forKey: UserDefaultsKey.showStatusBar) as? Bool ?? false
    }
    
    // Available monospace fonts on iOS
    // Note: Font list now centralized in FontMapping.swift
    static let fontFamilies = FontMapping.allDisplayNames
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
                    .accessibilityIdentifier("ThemePickerLink")
                }
                
                // Cursor Style
                Section {
                    HStack {
                        Text("Cursor")
                        Spacer()
                        Picker("", selection: $settings.cursorStyle) {
                            Text("Block").tag("block")
                            Text("Bar").tag("bar")
                            Text("Underline").tag("underline")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                        .accessibilityIdentifier("CursorStylePicker")
                    }
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
                    .accessibilityIdentifier("FontFamilyLink")
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
                            .accessibilityIdentifier("FontSizeSlider")
                            .accessibilityLabel("Font size")
                            .accessibilityValue("\(currentFontSize) points")
                            
                            Image(systemName: "textformat.size.larger")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    Button("Reset to Default (14 pt)") {
                        onResetFontSize()
                    }
                    .foregroundStyle(.blue)
                    .accessibilityIdentifier("ResetFontSizeButton")
                }
                
                // Interface
                Section("Interface") {
                    Toggle("Show Status Bar", isOn: $settings.showStatusBar)
                        .accessibilityIdentifier("ShowStatusBarToggle")
                    Text("Display iOS time, battery, and network indicators")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Appearance
                Section("Appearance") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Background Opacity")
                            Spacer()
                            Text("\(Int(settings.backgroundOpacity * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        
                        Slider(
                            value: $settings.backgroundOpacity,
                            in: 0.5...1.0,
                            step: 0.05
                        )
                        .accessibilityIdentifier("BackgroundOpacitySlider")
                        .accessibilityLabel("Background opacity")
                        .accessibilityValue("\(Int(settings.backgroundOpacity * 100)) percent")
                    }
                    .padding(.vertical, 4)
                    
                    Text("When less than 100%, apps behind the terminal will be visible. Use Cmd+U to toggle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Ghostty Configuration
                Section {
                    NavigationLink {
                        ConfigEditorView()
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.blue)
                            Text("Edit Config File")
                        }
                    }
                    .accessibilityIdentifier("ConfigEditorLink")
                } header: {
                    Text("Terminal Configuration")
                } footer: {
                    Text("Advanced: Edit the Ghostty config file directly. Changes apply on next connection.")
                }
                
                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("VersionLabel")
                    
                    HStack {
                        Text("Terminal Engine")
                        Spacer()
                        Text("Ghostty")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("TerminalEngineLabel")
                }
            }
            .listStyle(.insetGrouped)
            .preferredColorScheme(themeManager.selectedTheme.isDark ? .dark : .light)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("SettingsDoneButton")
                }
            }
            // Sync GUI changes to config file (file is source of truth)
            .onChange(of: settings.cursorStyle) { _, newValue in
                ConfigSyncManager.shared.updateCursorStyle(newValue)
                // Immediately reload so change is visible
                NotificationCenter.default.post(name: .reloadConfiguration, object: nil)
            }
            .onChange(of: settings.fontFamily) { _, newValue in
                ConfigSyncManager.shared.updateFontFamily(newValue)
                NotificationCenter.default.post(name: .reloadConfiguration, object: nil)
            }
            .onChange(of: settings.fontThicken) { _, newValue in
                ConfigSyncManager.shared.updateFontThicken(newValue)
                NotificationCenter.default.post(name: .reloadConfiguration, object: nil)
            }
            .onChange(of: themeManager.selectedTheme.id) { _, _ in
                // ThemeManager.selectTheme() already writes `theme = <name>` to config file
                // Just reload so Ghostty picks up the change
                NotificationCenter.default.post(name: .reloadConfiguration, object: nil)
            }
            .onChange(of: settings.backgroundOpacity) { _, newValue in
                ConfigSyncManager.shared.updateBackgroundOpacity(newValue)
                NotificationCenter.default.post(name: .reloadConfiguration, object: nil)
            }
            // No auto-reload on dismiss - changes are applied immediately above
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
        .listStyle(.insetGrouped)
        .preferredColorScheme(themeManager.selectedTheme.isDark ? .dark : .light)
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
        .accessibilityIdentifier("ThemeRow-\(theme.name)")
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
                        UserDefaults.standard.set(font, forKey: UserDefaultsKey.fontFamily)
                        // Call the callback on next run loop to ensure UserDefaults is synced
                        Task { @MainActor in
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
                .accessibilityIdentifier("FontRow-\(font)")
            }
        }
        .listStyle(.insetGrouped)
        .preferredColorScheme(ThemeManager.shared.selectedTheme.isDark ? .dark : .light)
        .navigationTitle("Font Family")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Config Editor

struct ConfigEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var configText: String = ""
    @State private var originalText: String = ""
    @State private var showResetConfirmation = false
    @State private var saveResult: SaveResult? = nil
    
    enum SaveResult {
        case success
        case failure(String)
    }
    
    private var configPath: URL {
        Ghostty.Config.configFilePath
    }
    
    private var hasChanges: Bool {
        configText != originalText
    }
    
    private var theme: TerminalTheme {
        themeManager.selectedTheme
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Syntax-highlighted editor
            HighlightedConfigEditor(
                text: $configText,
                theme: theme
            )
            .accessibilityIdentifier("ConfigTextEditor")
            
            // Status bar
            HStack {
                if let result = saveResult {
                    switch result {
                    case .success:
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let error):
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else if hasChanges {
                    Label("Modified", systemImage: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("No changes", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text(configPath.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(theme.background).opacity(0.8))
            .accessibilityIdentifier("ConfigStatusBar")
        }
        .background(Color(theme.background))
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .navigationTitle("Config Editor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if hasChanges {
                    Button("Discard") {
                        configText = originalText
                        saveResult = nil
                    }
                    .accessibilityIdentifier("ConfigDiscardButton")
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        saveConfig()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!hasChanges)
                    .accessibilityIdentifier("ConfigSaveButton")
                    
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .accessibilityIdentifier("ConfigResetButton")
                    
                    Divider()
                    
                    Button {
                        UIPasteboard.general.string = configText
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("ConfigCopyButton")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("ConfigMenuButton")
            }
        }
        .alert("Reset Configuration?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetToDefaults()
            }
        } message: {
            Text("This will replace your config with the default settings generated from app preferences.")
        }
        .onAppear {
            loadConfig()
        }
        .onDisappear {
            // Auto-save if there are changes, but suppress the success/error banner
            // since the view is disappearing and the user won't see it.
            if hasChanges {
                saveConfig(silent: true)
                // Sync config file changes back to GUI settings
                ConfigSyncManager.shared.onConfigFileChanged()
                // Reload terminal configuration
                NotificationCenter.default.post(name: .reloadConfiguration, object: nil)
            }
        }
    }
    
    private func loadConfig() {
        if FileManager.default.fileExists(atPath: configPath.path),
           let content = try? String(contentsOf: configPath, encoding: .utf8) {
            configText = content
            originalText = content
        } else {
            let defaultConfig = Ghostty.Config.getConfigString()
            configText = defaultConfig
            originalText = defaultConfig
        }
    }
    
    private func saveConfig(silent: Bool = false) {
        do {
            try configText.write(to: configPath, atomically: true, encoding: .utf8)
            originalText = configText
            if !silent {
                withAnimation {
                    saveResult = .success
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if case .success = saveResult {
                        withAnimation {
                            saveResult = nil
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed to save config: \(error.localizedDescription)")
            if !silent {
                withAnimation {
                    saveResult = .failure("Save failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func resetToDefaults() {
        let defaultConfig = Ghostty.Config.getConfigString()
        configText = defaultConfig
        saveConfig()
    }
}

// MARK: - Syntax Highlighted Text Editor

struct HighlightedConfigEditor: UIViewRepresentable {
    @Binding var text: String
    let theme: TerminalTheme
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardType = .asciiCapable
        textView.backgroundColor = UIColor(theme.background)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        return textView
    }
    
    func updateUIView(_ textView: UITextView, context: Context) {
        // Update background color if theme changed
        textView.backgroundColor = UIColor(theme.background)
        
        // Only update if text actually changed from outside
        if textView.text != text {
            let selectedRange = textView.selectedRange
            textView.attributedText = highlightedText(text)
            // Restore cursor position (selectedRange uses UTF-16 offsets)
            if selectedRange.location <= textView.text.utf16.count {
                textView.selectedRange = selectedRange
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func highlightedText(_ text: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: text.utf16.count)
        
        // Use theme colors from palette
        // Palette indices: 0=black, 1=red, 2=green, 3=yellow, 4=blue, 5=magenta, 6=cyan, 7=white
        let foregroundColor = UIColor(theme.foreground)
        let commentColor = UIColor(theme.palette[2]).withAlphaComponent(0.7) // green
        let keyColor = UIColor(theme.palette[6]) // cyan
        let valueColor = UIColor(theme.palette[3]) // yellow
        let stringColor = UIColor(theme.palette[5]) // magenta
        
        // Apply default styling
        attributed.addAttribute(.foregroundColor, value: foregroundColor, range: fullRange)
        attributed.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), range: fullRange)
        
        let lines = text.components(separatedBy: "\n")
        var currentIndex = 0
        
        for line in lines {
            let lineLength = line.utf16.count
            let lineRange = NSRange(location: currentIndex, length: lineLength)
            
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("#") {
                // Comment line - green/dim
                attributed.addAttribute(.foregroundColor, value: commentColor, range: lineRange)
            } else if let equalsIndex = line.firstIndex(of: "=") {
                // Key = Value line
                let keyEndIndex = line.distance(from: line.startIndex, to: equalsIndex)
                let keyRange = NSRange(location: currentIndex, length: keyEndIndex)
                attributed.addAttribute(.foregroundColor, value: keyColor, range: keyRange)
                
                // Value part (after =)
                let valueStart = currentIndex + keyEndIndex + 1
                let valueLength = lineLength - keyEndIndex - 1
                if valueLength > 0 {
                    let valueRange = NSRange(location: valueStart, length: valueLength)
                    attributed.addAttribute(.foregroundColor, value: valueColor, range: valueRange)
                    
                    // Check for quoted strings within value
                    let valueString = String(line[line.index(after: equalsIndex)...])
                    if let quoteStart = valueString.firstIndex(of: "\""),
                       let quoteEnd = valueString.lastIndex(of: "\""),
                       quoteStart != quoteEnd {
                        let quoteStartOffset = valueString.distance(from: valueString.startIndex, to: quoteStart)
                        let quoteEndOffset = valueString.distance(from: valueString.startIndex, to: quoteEnd)
                        let stringRange = NSRange(location: valueStart + quoteStartOffset, length: quoteEndOffset - quoteStartOffset + 1)
                        attributed.addAttribute(.foregroundColor, value: stringColor, range: stringRange)
                    }
                }
            }
            
            currentIndex += lineLength + 1 // +1 for newline
        }
        
        return attributed
    }
    
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: HighlightedConfigEditor
        
        /// Debounce work item — cancels previous highlighting on each keystroke
        /// so re-highlighting only runs after typing pauses (~150ms).
        private var highlightWorkItem: DispatchWorkItem?
        
        init(_ parent: HighlightedConfigEditor) {
            self.parent = parent
        }
        
        func textViewDidChange(_ textView: UITextView) {
            // Update binding immediately so the text is always current
            parent.text = textView.text
            
            // Cancel any pending highlight work
            highlightWorkItem?.cancel()
            
            // Debounce re-highlighting to avoid re-parsing on every keystroke
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let selectedRange = textView.selectedRange
                textView.attributedText = self.parent.highlightedText(textView.text)
                // Restore cursor (selectedRange uses UTF-16 offsets)
                if selectedRange.location <= textView.text.utf16.count {
                    textView.selectedRange = selectedRange
                }
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }
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

