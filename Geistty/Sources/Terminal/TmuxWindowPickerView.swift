//
//  TmuxWindowPickerView.swift
//  Geistty
//
//  A horizontal tab bar showing tmux windows, allowing switching between them.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.geistty", category: "TmuxWindowPicker")

/// A horizontal tab bar showing tmux windows
struct TmuxWindowPickerView: View {
    @ObservedObject var sessionManager: TmuxSessionManager
    
    /// Callback when rename is requested (window ID, current name)
    var onRenameRequested: ((String, String) -> Void)?
    
    /// Height of the window picker bar
    private let barHeight: CGFloat = 36
    
    /// Background color
    private let backgroundColor = Color(white: 0.12)
    
    /// Get windows sorted by index
    private var sortedWindows: [TmuxWindow] {
        sessionManager.windows.values.sorted { $0.index < $1.index }
    }
    
    /// Callback when session picker is requested
    var onSessionPickerRequested: (() -> Void)?
    
    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                // Session name button (opens session picker)
                if let session = sessionManager.currentSession {
                    Button {
                        onSessionPickerRequested?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 10))
                            Text(session.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(white: 0.16))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("TmuxSessionButton")
                    
                    // Divider between session name and window tabs
                    Rectangle()
                        .fill(Color(white: 0.25))
                        .frame(width: 1, height: 20)
                        .padding(.horizontal, 4)
                }
                
                // Window tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(sortedWindows) { window in
                            WindowTab(
                                window: window,
                                isSelected: window.id == sessionManager.focusedWindowId,
                                onSelect: {
                                    selectWindow(window)
                                },
                                onClose: {
                                    closeWindow(window)
                                },
                                onRename: {
                                    onRenameRequested?(window.id, window.name)
                                }
                            )
                            .id(window.id)
                        }
                        
                        // New window button
                        Button(action: {
                            sessionManager.newWindow()
                        }) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("TmuxNewWindowButton")
                    }
                    .padding(.horizontal, 8)
                }
            }
            .frame(height: barHeight)
            .background(backgroundColor)
            .onChange(of: sessionManager.focusedWindowId) { _, newWindowId in
                // Scroll to focused window when it changes
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newWindowId, anchor: .center)
                }
            }
        }
    }
    
    private func selectWindow(_ window: TmuxWindow) {
        logger.info("📑 TmuxWindowPickerView.selectWindow: \(window.id) '\(window.name)'")
        logger.info("📑   Current focusedWindowId: \(sessionManager.focusedWindowId)")
        logger.info("📑   Current split tree panes: \(sessionManager.currentSplitTree.paneIds.count)")
        sessionManager.selectWindow(window.id)
        logger.info("📑   After selectWindow - focusedWindowId: \(sessionManager.focusedWindowId)")
    }
    
    private func closeWindow(_ window: TmuxWindow) {
        logger.info("Closing window: \(window.id) '\(window.name)'")
        sessionManager.closeWindow(windowId: window.id)
    }
}

/// A single window tab in the picker
private struct WindowTab: View {
    let window: TmuxWindow
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    
    /// Tab background colors
    private var backgroundColor: Color {
        isSelected ? Color(white: 0.2) : Color.clear
    }
    
    /// Tab text color
    private var textColor: Color {
        isSelected ? .white : .secondary
    }
    
    /// Whether to show close button (always for selected, on hover for others)
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 4) {
            // Window index badge
            Text("\(window.index)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(minWidth: 14)
            
            // Window name
            Text(window.name)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundColor(textColor)
                .lineLimit(1)
            
            // Close button (show when selected or hovering)
            if isSelected || isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .onTapGesture(count: 1) {
            // Single tap to select
            // Rename is available via context menu (long-press / right-click).
            // The previous double-tap gesture caused a 300ms delay on every
            // single tap because SwiftUI waits for the second tap timeout.
            onSelect()
        }
        .contextMenu {
            Button {
                onRename()
            } label: {
                Label("Rename Window", systemImage: "pencil")
            }
            
            Button(role: .destructive) {
                onClose()
            } label: {
                Label("Close Window", systemImage: "xmark")
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityIdentifier("TmuxWindowTab-\(window.id)")
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Preview

#Preview {
    // Create mock session manager for preview
    let manager = TmuxSessionManager()
    
    return VStack {
        TmuxWindowPickerView(sessionManager: manager)
        Spacer()
    }
    .background(Color.black)
}
