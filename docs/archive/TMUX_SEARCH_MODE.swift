// TMUX_SEARCH_MODE.swift
// Archived: Feb 2026
//
// Dead tmux search mode code removed during v0.1-stable cleanup.
// This code implemented a "capture-pane" based search for tmux sessions,
// but captureTmuxPane() was stubbed to always fail after migration to
// Ghostty's native tmux handling (viewer.zig). Ghostty's built-in
// search works as fallback. The code is preserved here for reference
// if we ever need to revive tmux-specific search.
//
// Files affected:
// - Ghostty.swift (SearchMode enum, SearchState tmux properties)
// - SurfaceSearchOverlay.swift (tmux search branches)
// - TerminalContainerView.swift (captureTmuxPane stub, tmuxGotoLine, callback wiring)

// ============================================================
// FROM: Ghostty.swift — SearchMode enum and SearchState tmux fields
// ============================================================

/*
/// Search mode - determines which buffer to search
enum SearchMode {
    case ghostty  // Normal Ghostty scrollback search
    case tmux     // Search tmux's internal scrollback via capture-pane
}

// On SearchState class:

/// The search mode (ghostty vs tmux)
@Published var searchMode: SearchMode = .ghostty

/// Captured tmux pane content (for tmux search mode)
@Published var tmuxContent: String? = nil

/// Positions of matches in tmux content (line numbers)
@Published var tmuxMatchLines: [Int] = []

/// Whether a tmux capture is in progress
@Published var isCapturing: Bool = false

/// Error message if capture failed
@Published var captureError: String? = nil

// In reset():
searchMode = .ghostty
tmuxContent = nil
tmuxMatchLines = []
isCapturing = false
captureError = nil
*/

// ============================================================
// FROM: TerminalContainerView.swift — captureTmuxPane() and tmuxGotoLine()
// ============================================================

/*
/// Capture tmux pane content for search
/// - Parameter completion: Called with the captured content or error
/// NOTE: capture-pane requires command/response pattern which is not available
/// after migration to Ghostty's native tmux. Ghostty's native search should be
/// used instead. This stub remains to keep the search overlay wiring compilable.
func captureTmuxPane(completion: @escaping (Result<String, Error>) -> Void) {
    // capture-pane requires the old gateway command/response pattern.
    // With Ghostty handling tmux natively, use Ghostty's built-in search instead.
    completion(.failure(NSError(
        domain: "com.geistty",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Tmux pane capture not available — use terminal search"]
    )))
}

/// Navigate to a specific line in tmux using copy mode
/// - Parameter lineNumber: The line number to navigate to (0-based from top of scrollback)
func tmuxGotoLine(_ lineNumber: Int) {
    // Send tmux prefix (Ctrl+B) then copy-mode key ([)
    // Then navigate to the line using tmux copy-mode commands
    // Ctrl+B = \u{02}, [ enters copy mode
    // g goes to top, then we can use : to go to line number
    
    // Enter copy mode: Ctrl+B [
    send(text: "\u{02}[")
    
    // Small delay then go to top and line
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        // g = go to top of history
        self?.send(text: "g")
        
        // Then go down to the target line
        // In tmux copy mode, we can use : followed by line number
        // Or just send the line number followed by Enter for goto-line
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            // : enters command mode, then line number
            self?.send(text: ":\(lineNumber)\r")
        }
    }
}
*/

// ============================================================
// FROM: TerminalContainerView.swift — updateSearchOverlay() callback wiring
// ============================================================

/*
// In updateSearchOverlay(), creating tmux callbacks:

// Create tmux callbacks if this is a tmux session
let tmuxCaptureCallback: ((@escaping (Result<String, Error>) -> Void) -> Void)?
let tmuxGotoLineCallback: ((Int) -> Void)?

if let vm = viewModel, vm.isTmuxSession {
    tmuxCaptureCallback = { [weak vm] completion in
        vm?.captureTmuxPane(completion: completion)
    }
    tmuxGotoLineCallback = { [weak vm] lineNumber in
        vm?.tmuxGotoLine(lineNumber)
    }
} else {
    tmuxCaptureCallback = nil
    tmuxGotoLineCallback = nil
}

// And passed to overlay:
let overlay = Ghostty.SurfaceSearchOverlay(
    surfaceView: surface,
    searchState: searchState,
    onClose: { [weak self] in
        self?.closeSearch()
    },
    onCaptureTmux: tmuxCaptureCallback,
    onTmuxGotoLine: tmuxGotoLineCallback
)
*/

// ============================================================
// FROM: SurfaceSearchOverlay.swift — Full tmux search mode implementation
// ============================================================

/*
// Properties:
/// Callback to capture tmux pane content (optional - nil if not in tmux)
var onCaptureTmux: ((@escaping (Result<String, Error>) -> Void) -> Void)?

/// Callback to navigate to a line in tmux copy mode
var onTmuxGotoLine: ((Int) -> Void)?

// In onAppear:
// If we have tmux capture capability, use tmux search mode immediately
if onCaptureTmux != nil {
    captureTmuxPaneContent()
}

// Helpers:

/// Whether to use tmux search (alternate screen + tmux callback available)
private var shouldUseTmuxSearch: Bool {
    searchState.isAlternateScreen && onCaptureTmux != nil
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
                if !searchState.needle.isEmpty {
                    searchTmuxContent(searchState.needle)
                }
                
            case .failure(let error):
                searchState.captureError = error.localizedDescription
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

// In handleSearchQueryChanged — tmux branch:
if searchState.searchMode == .tmux {
    searchState.total = nil
    searchState.selected = nil
    searchState.tmuxMatchLines = []
}

// In performSearch — tmux branch:
if searchState.searchMode == .tmux {
    searchTmuxContent(query)
}

// In navigateNext/navigatePrevious — tmux branches:
if searchState.searchMode == .tmux {
    navigateTmuxNext()
} else {
    surfaceView.searchNext()
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
    
    let lineNumber = searchState.tmuxMatchLines[prev]
    onTmuxGotoLine?(lineNumber)
}

// In resultCountView — tmux indicators:
if searchState.isCapturing {
    ProgressView()
        .scaleEffect(0.6)
}
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
*/
