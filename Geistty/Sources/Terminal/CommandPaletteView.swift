//
//  CommandPaletteView.swift
//  Geistty
//
//  Command palette overlay for searching and executing Ghostty commands.
//  iOS adaptation of upstream Ghostty macOS CommandPalette.swift.
//
//  Key differences from upstream macOS version:
//  - No hover states (no mouse cursor on iOS)
//  - No ResponderChainInjector (NSView-specific)
//  - No color matching (NSColor.colorNames not available)
//  - No update commands or jump-to-surface commands (single-window iOS app)
//  - Uses UIColor instead of NSColor
//

import SwiftUI
import GhosttyKit
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "CommandPalette")

// MARK: - Command Palette View

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let commands: [Ghostty.Command]
    let onAction: (String) -> Void

    @State private var query = ""
    @State private var selectedIndex: Int?
    @FocusState private var isTextFieldFocused: Bool

    private var filteredCommands: [Ghostty.Command] {
        let supported = commands.filter(\.isSupported)
        if query.isEmpty {
            return supported
        }
        return supported.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedCommand: Ghostty.Command? {
        guard let idx = selectedIndex, idx < filteredCommands.count else { return nil }
        return filteredCommands[idx]
    }

    var body: some View {
        ZStack {
            // Dismiss background
            if isPresented {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }

                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        VStack(alignment: .leading, spacing: 0) {
                            // Search field
                            commandPaletteQuery

                            Divider()

                            // Results list
                            commandTable
                        }
                        .frame(maxWidth: 500)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                        .shadow(radius: 32, x: 0, y: 12)
                        .padding(.horizontal)

                        Spacer()
                    }
                    .frame(width: geometry.size.width, alignment: .top)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isPresented)
        .onChange(of: isPresented) { _, newValue in
            if newValue {
                query = ""
                selectedIndex = nil
                isTextFieldFocused = true
            }
        }
    }

    // MARK: - Query Field

    private var commandPaletteQuery: some View {
        ZStack {
            // Hidden buttons for keyboard navigation (same pattern as upstream)
            Group {
                Button { moveSelection(by: -1) } label: { Color.clear }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button { moveSelection(by: 1) } label: { Color.clear }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.downArrow, modifiers: [])
                // Ctrl+P / Ctrl+N (Emacs-style)
                Button { moveSelection(by: -1) } label: { Color.clear }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.init("p"), modifiers: [.control])
                Button { moveSelection(by: 1) } label: { Color.clear }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.init("n"), modifiers: [.control])
                // Escape to dismiss (T10)
                Button { dismiss() } label: { Color.clear }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            TextField("Execute a command\u{2026}", text: $query)
                .padding()
                .font(.system(size: 18, weight: .light))
                .frame(height: 48)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isTextFieldFocused)
                .onSubmit { submitSelected() }
                .accessibilityIdentifier("CommandPaletteSearchField")
                .onChange(of: query) { _, newValue in
                    if !newValue.isEmpty {
                        if selectedIndex == nil { selectedIndex = 0 }
                    } else {
                        if selectedIndex == 0 { selectedIndex = nil }
                    }
                }
        }
    }

    // MARK: - Results Table

    private var commandTable: some View {
        Group {
            if filteredCommands.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(filteredCommands.enumerated()), id: \.1.action) { index, command in
                                CommandRow(
                                    command: command,
                                    isSelected: selectedIndex == index
                                ) {
                                    execute(command)
                                }
                                .id(command.action)
                            }
                        }
                        .padding(10)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: selectedIndex) { _, newIndex in
                        guard let newIndex, newIndex < filteredCommands.count else { return }
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(filteredCommands[newIndex].action, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func moveSelection(by delta: Int) {
        guard !filteredCommands.isEmpty else { return }
        let count = filteredCommands.count
        if let current = selectedIndex {
            selectedIndex = (current + delta + count) % count
        } else {
            selectedIndex = delta > 0 ? 0 : count - 1
        }
    }

    private func submitSelected() {
        if let command = selectedCommand {
            execute(command)
        }
    }

    private func execute(_ command: Ghostty.Command) {
        logger.info("Executing command: \(command.title) (\(command.action))")
        dismiss()
        onAction(command.action)
    }

    private func dismiss() {
        isPresented = false
        isTextFieldFocused = false
    }
}

// MARK: - Command Row

private struct CommandRow: View {
    let command: Ghostty.Command
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.body)

                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.2)
                    : Color.clear
            )
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(command.title)
        .accessibilityHint(command.description)
    }
}

// MARK: - UIKit Bridge

/// Observable state object for bridging UIKit VC toggle with SwiftUI binding.
class CommandPaletteState: ObservableObject {
    @Published var isPresented: Bool = false
}

/// Wrapper view that bridges CommandPaletteState (class) with CommandPaletteView (binding).
/// Monitors `isPresented` and calls `onDismiss` when the palette is dismissed from within.
struct CommandPaletteWrapper: View {
    @ObservedObject var state: CommandPaletteState
    let commands: [Ghostty.Command]
    let onAction: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        CommandPaletteView(
            isPresented: $state.isPresented,
            commands: commands,
            onAction: onAction
        )
        .onChange(of: state.isPresented) { _, newValue in
            if !newValue {
                onDismiss()
            }
        }
    }
}
