//
//  SurfaceSearchOverlay.swift
//  Bodak
//
//  Search overlay for the terminal, adapted from macOS Ghostty implementation
//

import SwiftUI
import Combine

extension Ghostty {
    /// Search overlay view that appears when search is active
    /// Adapted from macOS Ghostty with iPadOS best practices
    struct SurfaceSearchOverlay: View {
        /// The surface view to search in
        let surfaceView: SurfaceView
        
        /// The search state (observable for live updates)
        @ObservedObject var searchState: SearchState
        
        /// Callback when search should close
        let onClose: () -> Void
        
        /// Callback to capture tmux pane content (optional - nil if not in tmux)
        var onCaptureTmux: ((@escaping (Result<String, Error>) -> Void) -> Void)?
        
        /// Callback to navigate to a line in tmux copy mode
        var onTmuxGotoLine: ((Int) -> Void)?
        
        /// Focus state for the search text field
        @FocusState private var isSearchFieldFocused: Bool
        
        /// Padding from edges
        private let padding: CGFloat = 12
        
        /// Debounce timer for search input
        @State private var searchDebounceTimer: Timer?
        
        var body: some View {
            // Just the search bar - positioning is handled by UIKit
            searchBarView
        }
        
        // MARK: - Search Bar
        
        @ViewBuilder
        private var searchBarView: some View {
            HStack(spacing: 8) {
                // Search text field with result count overlay
                TextField("Search", text: $searchState.needle)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                    .padding(.leading, 12)
                    .padding(.trailing, resultCountWidth)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray5))
                    .cornerRadius(8)
                    .focused($isSearchFieldFocused)
                    .overlay(alignment: .trailing) {
                        resultCountView
                            .padding(.trailing, 8)
                    }
                    .onChange(of: searchState.needle) { _, newValue in
                        handleSearchQueryChanged(newValue)
                    }
                    .onSubmit {
                        // Return key: navigate to next result
                        navigateNext()
                    }
                    .onKeyPress(.escape) {
                        // Escape key: close search
                        onClose()
                        return .handled
                    }
                
                // Previous result button (chevron up = go to previous)
                Button(action: navigatePrevious) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(SearchButtonStyle())
                .accessibilityLabel("Previous result")
                .disabled(searchState.total == 0 || searchState.isCapturing)
                
                // Next result button (chevron down = go to next)
                Button(action: navigateNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(SearchButtonStyle())
                .accessibilityLabel("Next result")
                .disabled(searchState.total == 0 || searchState.isCapturing)
                
                // Close button
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(SearchButtonStyle())
                .accessibilityLabel("Close search")
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
            .onAppear {
                isSearchFieldFocused = true
                // If we have tmux capture capability, use tmux search mode immediately
                if onCaptureTmux != nil {
                    captureTmuxPaneContent()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttySearchFocus)) { notification in
                guard notification.object as? SurfaceView === surfaceView else { return }
                isSearchFieldFocused = true
            }
        }
        
        // MARK: - Search Helpers
        
        /// Whether to use tmux search (alternate screen + tmux callback available)
        private var shouldUseTmuxSearch: Bool {
            searchState.isAlternateScreen && onCaptureTmux != nil
        }
        
        /// Handle search query changes
        private func handleSearchQueryChanged(_ query: String) {
            // Cancel previous debounce timer
            searchDebounceTimer?.invalidate()
            
            guard !query.isEmpty else {
                // Clear search
                if searchState.searchMode == .tmux {
                    searchState.total = nil
                    searchState.selected = nil
                    searchState.tmuxMatchLines = []
                } else {
                    surfaceView.updateSearch(query)
                }
                return
            }
            
            // Debounce search (wait for user to stop typing)
            searchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
                Task { @MainActor in
                    performSearch(query)
                }
            }
        }
        
        /// Perform the search (either Ghostty or tmux mode)
        private func performSearch(_ query: String) {
            if searchState.searchMode == .tmux {
                // Search in captured tmux content
                searchTmuxContent(query)
            } else {
                // Use Ghostty's native search
                surfaceView.updateSearch(query)
            }
        }
        
        /// Capture tmux pane content and switch to tmux search mode
        private func captureTmuxPaneContent() {
            guard let onCaptureTmux = onCaptureTmux else { return }
            
            searchState.isCapturing = true
            searchState.captureError = nil
            searchState.searchMode = .tmux
            
            onCaptureTmux { result in
                Task { @MainActor in
                    searchState.isCapturing = false
                    
                    switch result {
                    case .success(let content):
                        searchState.tmuxContent = content
                        // If there's already a query, search it
                        if !searchState.needle.isEmpty {
                            searchTmuxContent(searchState.needle)
                        }
                        
                    case .failure(let error):
                        searchState.captureError = error.localizedDescription
                        // Fall back to Ghostty search
                        searchState.searchMode = .ghostty
                    }
                }
            }
        }
        
        /// Search within captured tmux content
        private func searchTmuxContent(_ query: String) {
            guard let content = searchState.tmuxContent else {
                searchState.total = 0
                return
            }
            
            // Find all line numbers containing the query (case-insensitive)
            let lines = content.components(separatedBy: "\n")
            var matchLines: [Int] = []
            
            for (index, line) in lines.enumerated() {
                if line.localizedCaseInsensitiveContains(query) {
                    matchLines.append(index)
                }
            }
            
            searchState.tmuxMatchLines = matchLines
            searchState.total = UInt(matchLines.count)
            searchState.selected = matchLines.isEmpty ? nil : 0
        }
        
        /// Navigate to next result
        private func navigateNext() {
            if searchState.searchMode == .tmux {
                navigateTmuxNext()
            } else {
                surfaceView.searchNext()
            }
        }
        
        /// Navigate to previous result
        private func navigatePrevious() {
            if searchState.searchMode == .tmux {
                navigateTmuxPrevious()
            } else {
                surfaceView.searchPrevious()
            }
        }
        
        /// Navigate to next tmux match
        private func navigateTmuxNext() {
            guard !searchState.tmuxMatchLines.isEmpty else { return }
            guard let current = searchState.selected else {
                searchState.selected = 0
                return
            }
            
            let next = (Int(current) + 1) % searchState.tmuxMatchLines.count
            searchState.selected = UInt(next)
            
            // Navigate in tmux
            let lineNumber = searchState.tmuxMatchLines[next]
            onTmuxGotoLine?(lineNumber)
        }
        
        /// Navigate to previous tmux match
        private func navigateTmuxPrevious() {
            guard !searchState.tmuxMatchLines.isEmpty else { return }
            guard let current = searchState.selected else {
                searchState.selected = UInt(searchState.tmuxMatchLines.count - 1)
                return
            }
            
            let count = searchState.tmuxMatchLines.count
            let prev = (Int(current) - 1 + count) % count
            searchState.selected = UInt(prev)
            
            // Navigate in tmux
            let lineNumber = searchState.tmuxMatchLines[prev]
            onTmuxGotoLine?(lineNumber)
        }
        
        // MARK: - Result Count View
        
        private var resultCountWidth: CGFloat { 80 }
        
        @ViewBuilder
        private var resultCountView: some View {
            HStack(spacing: 4) {
                // Show capturing indicator
                if searchState.isCapturing {
                    ProgressView()
                        .scaleEffect(0.6)
                }
                // tmux search mode indicator
                else if searchState.searchMode == .tmux {
                    Text("tmux")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(4)
                }
                // Alternate screen indicator (when not using tmux search)
                else if searchState.isAlternateScreen {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .help("Alternate screen mode - search limited to visible content")
                }
                
                // Result count
                if let selected = searchState.selected {
                    Text("\(selected + 1)/\(searchState.total.map { String($0) } ?? "?")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                } else if let total = searchState.total {
                    Text("-/\(total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        }
        
    }
    
    // MARK: - Search Button Style
    
    struct SearchButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(configuration.isPressed ? .primary : .secondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(configuration.isPressed ? Color(.systemGray4) : Color.clear)
                )
                .contentShape(Rectangle())
        }
    }
}
