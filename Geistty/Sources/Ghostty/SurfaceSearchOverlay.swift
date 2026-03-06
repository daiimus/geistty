//
//  SurfaceSearchOverlay.swift
//  Geistty
//
//  Search overlay for the terminal, adapted from macOS Ghostty implementation
//

import SwiftUI

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
        
        /// Focus state for the search text field
        @FocusState private var isSearchFieldFocused: Bool
        
        /// Padding from edges
        private let padding: CGFloat = 12
        
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
                    .accessibilityIdentifier("SearchTextField")
                    .overlay(alignment: .trailing) {
                        resultCountView
                            .padding(.trailing, 8)
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
                .accessibilityIdentifier("SearchPreviousButton")
                .disabled(searchState.total == 0)
                
                // Next result button (chevron down = go to next)
                Button(action: navigateNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(SearchButtonStyle())
                .accessibilityLabel("Next result")
                .accessibilityIdentifier("SearchNextButton")
                .disabled(searchState.total == 0)
                
                // Close button
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(SearchButtonStyle())
                .accessibilityLabel("Close search")
                .accessibilityIdentifier("SearchCloseButton")
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
            .onAppear {
                isSearchFieldFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttySearchFocus)) { notification in
                guard notification.object as? SurfaceView === surfaceView else { return }
                isSearchFieldFocused = true
            }
        }
        
        // MARK: - Search Helpers
        
        /// Navigate to next result
        private func navigateNext() {
            surfaceView.searchNext()
        }
        
        /// Navigate to previous result
        private func navigatePrevious() {
            surfaceView.searchPrevious()
        }
        
        // MARK: - Result Count View
        
        private var resultCountWidth: CGFloat { 80 }
        
        @ViewBuilder
        private var resultCountView: some View {
            HStack(spacing: 4) {
                // Alternate screen indicator
                if searchState.isAlternateScreen {
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
