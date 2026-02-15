//
//  Ghostty.SearchState.swift
//  Geistty
//
//  Search state and error types for Ghostty terminal surfaces.
//  Extracted from Ghostty.swift — follows upstream Ghostty macOS naming convention.
//

import Foundation

// MARK: - Errors

extension Ghostty {
    enum GhosttyError: LocalizedError {
        case initFailed
        case surfaceCreationFailed
        case notReady
        
        var errorDescription: String? {
            switch self {
            case .initFailed:
                return "Failed to initialize Ghostty"
            case .surfaceCreationFailed:
                return "Failed to create terminal surface"
            case .notReady:
                return "Ghostty app is not ready"
            }
        }
    }
    
    // MARK: - Search State
    
    /// Observable search state for the terminal, matching macOS Ghostty implementation
    class SearchState: ObservableObject {
        /// The current search query (needle)
        @Published var needle: String = ""
        
        /// Total number of search matches (nil if unknown/not searched yet)
        @Published var total: UInt? = nil
        
        /// Currently selected match index (nil if no selection)
        @Published var selected: UInt? = nil
        
        /// Whether the terminal is on alternate screen (e.g., tmux, vim)
        /// When true, search only sees visible rows (no scrollback)
        @Published var isAlternateScreen: Bool = false
        
        /// Initialize with optional starting query
        init(needle: String = "") {
            self.needle = needle
        }
        
        /// Reset search state
        func reset() {
            needle = ""
            total = nil
            selected = nil
            isAlternateScreen = false
        }
    }
}
