//
//  TmuxSessionPickerView.swift
//  Geistty
//
//  A modal sheet for listing, switching, creating, renaming, and
//  destroying tmux sessions. Presented from the window picker or
//  menu bar.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.geistty", category: "TmuxSessionPicker")

/// Delay before refreshing the session list after a fire-and-forget mutation
/// (kill, rename). These commands use `sendCommandFireAndForget` which bypasses
/// the command/response pipeline, so we can't trigger refresh on response.
/// The delay gives tmux time to process the mutation before we re-query.
private let sessionRefreshDelay: TimeInterval = 0.3

// MARK: - Session Picker View

struct TmuxSessionPickerView: View {
    @ObservedObject var sessionManager: TmuxSessionManager
    @Binding var isPresented: Bool
    
    /// Text field for new session name
    @State private var newSessionName: String = ""
    @State private var isCreatingSession: Bool = false
    
    /// Text field for rename
    @State private var renamingSessionId: String? = nil
    @State private var renameText: String = ""
    
    /// Tracks whether we've completed at least one listSessions() fetch.
    /// Distinguishes "still loading" from "loaded but empty" (no sessions).
    @State private var didLoadSessions: Bool = false
    
    var body: some View {
        NavigationView {
            List {
                // Existing sessions
                Section {
                    if sessionManager.availableSessions.isEmpty && !didLoadSessions {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Loading sessions\u{2026}")
                                .foregroundStyle(.secondary)
                        }
                    } else if sessionManager.availableSessions.isEmpty {
                        Text("No sessions available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sessionManager.availableSessions) { session in
                            SessionRow(
                                session: session,
                                isRenaming: renamingSessionId == session.id,
                                renameText: $renameText,
                                onSelect: {
                                    selectSession(session)
                                },
                                onRenameCommit: {
                                    commitRename(session)
                                },
                                onRenameCancel: {
                                    renamingSessionId = nil
                                }
                            )
                            .contextMenu {
                                sessionContextMenu(for: session)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !session.isCurrent {
                                    Button(role: .destructive) {
                                        killSession(session)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Sessions")
                }
                
                // New session
                Section {
                    if isCreatingSession {
                        HStack {
                            TextField("Session name (optional)", text: $newSessionName)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            
                            Button("Create") {
                                createSession()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            
                            Button("Cancel") {
                                isCreatingSession = false
                                newSessionName = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        Button {
                            isCreatingSession = true
                        } label: {
                            Label("New Session", systemImage: "plus")
                        }
                    }
                }
            }
            .navigationTitle("tmux Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        sessionManager.listSessions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh sessions")
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
        .onAppear {
            // Fetch sessions when sheet appears
            sessionManager.listSessions()
        }
        .onReceive(sessionManager.$availableSessions) { _ in
            didLoadSessions = true
        }
        .accessibilityIdentifier("TmuxSessionPicker")
    }
    
    // MARK: - Context Menu
    
    @ViewBuilder
    private func sessionContextMenu(for session: TmuxSessionInfo) -> some View {
        if !session.isCurrent {
            Button {
                selectSession(session)
            } label: {
                Label("Switch to Session", systemImage: "arrow.right.circle")
            }
        }
        
        Button {
            renamingSessionId = session.id
            renameText = session.name
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        
        if !session.isCurrent {
            Divider()
            
            Button(role: .destructive) {
                killSession(session)
            } label: {
                Label("Kill Session", systemImage: "trash")
            }
        }
    }
    
    // MARK: - Actions
    
    private func selectSession(_ session: TmuxSessionInfo) {
        guard !session.isCurrent else { return }
        logger.info("Switching to session \(session.id) '\(session.name)'")
        sessionManager.switchSession(sessionId: session.id)
        isPresented = false
    }
    
    private func killSession(_ session: TmuxSessionInfo) {
        logger.info("Killing session \(session.id) '\(session.name)'")
        sessionManager.killSession(sessionId: session.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + sessionRefreshDelay) {
            sessionManager.listSessions()
        }
    }
    
    private func createSession() {
        let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Creating new session\(name.isEmpty ? "" : " '\(name)'")")
        sessionManager.newSession(name: name.isEmpty ? nil : name, andSwitch: true)
        newSessionName = ""
        isCreatingSession = false
        isPresented = false
    }
    
    private func commitRename(_ session: TmuxSessionInfo) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            renamingSessionId = nil
            return
        }
        logger.info("Renaming session \(session.id) to '\(name)'")
        sessionManager.renameSession(sessionId: session.id, name: name)
        renamingSessionId = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + sessionRefreshDelay) {
            sessionManager.listSessions()
        }
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: TmuxSessionInfo
    let isRenaming: Bool
    @Binding var renameText: String
    let onSelect: () -> Void
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void
    
    var body: some View {
        if isRenaming {
            HStack {
                TextField("Session name", text: $renameText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { onRenameCommit() }
                
                Button("Save") { onRenameCommit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                
                Button("Cancel") { onRenameCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            Button(action: onSelect) {
                HStack {
                    // Current session indicator
                    if session.isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 14))
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(session.name)
                                .font(.body.weight(session.isCurrent ? .semibold : .regular))
                                .foregroundStyle(session.isCurrent ? .primary : .primary)
                            
                            Text(session.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        
                        HStack(spacing: 8) {
                            Label("\(session.windowCount)", systemImage: "rectangle.stack")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            if session.isAttached {
                                Label("attached", systemImage: "link")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    if !session.isCurrent {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.isCurrent)
            .accessibilityIdentifier("TmuxSessionRow-\(session.id)")
        }
    }
}

// MARK: - UIKit Presentation Container

/// Thin wrapper that owns the `isPresented` state and forwards dismissal
/// to a UIKit callback. Used by `showSessionPicker()` in the view controller.
struct SessionPickerContainer: View {
    @ObservedObject var sessionManager: TmuxSessionManager
    var onDismiss: () -> Void
    
    @State private var isPresented: Bool = true
    
    var body: some View {
        TmuxSessionPickerView(
            sessionManager: sessionManager,
            isPresented: $isPresented
        )
        .onChange(of: isPresented) { _, newValue in
            if !newValue {
                onDismiss()
            }
        }
    }
}
