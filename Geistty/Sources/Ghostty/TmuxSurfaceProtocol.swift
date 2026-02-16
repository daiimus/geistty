//
//  TmuxSurfaceProtocol.swift
//  Geistty
//
//  Protocol abstracting Ghostty surface tmux C API methods.
//  Enables unit testing of tmux lifecycle code without a real Ghostty surface.
//
//  SurfaceView conforms to this protocol with minimal changes (it already
//  has all the required methods). Tests use MockTmuxSurface instead.
//

import Foundation

/// Info about a tmux window, decoupled from Ghostty types.
/// Used by both the real SurfaceView and test mocks.
struct TmuxWindowInfo {
    let id: Int
    let width: Int
    let height: Int
    let name: String
}

/// Protocol for querying and controlling tmux state on a Ghostty surface.
///
/// This abstracts the tmux C API wrappers on `Ghostty.SurfaceView` so that
/// `SSHSession` and `TmuxSessionManager` can be tested without a real
/// GhosttyKit surface. The real `SurfaceView` conforms naturally —
/// all methods already exist.
///
/// Following Ghostty's convention of clean input/output interfaces that
/// are testable without I/O (see viewer.zig's TestStep pattern).
@MainActor
protocol TmuxSurfaceProtocol: AnyObject {
    // MARK: - Pane Queries
    
    /// Number of tmux panes (0 if not in tmux mode)
    var tmuxPaneCount: Int { get }
    
    /// IDs of all tmux panes
    func getTmuxPaneIds() -> [Int]
    
    /// Set which tmux pane the renderer displays. Returns true on success.
    @discardableResult
    func setActiveTmuxPane(_ paneId: Int) -> Bool
    
    // MARK: - Window Queries
    
    /// Number of tmux windows (0 if not in tmux mode)
    var tmuxWindowCount: Int { get }
    
    /// Info about all tmux windows
    func getAllTmuxWindows() -> [TmuxWindowInfo]
    
    /// Layout string for a window by index
    func getTmuxWindowLayout(at index: Int) -> String?
    
    /// Active tmux window ID (-1 if none)
    var tmuxActiveWindowId: Int { get }
    
    // MARK: - Input
    
    /// Send text input (routed through Ghostty for send-keys wrapping in tmux mode)
    func sendText(_ text: String)
}
