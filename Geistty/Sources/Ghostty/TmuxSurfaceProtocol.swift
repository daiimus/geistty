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
    
    /// Set which tmux pane the renderer displays AND routes input to.
    /// Swaps renderer_state.terminal to the pane's terminal.
    /// Returns true on success.
    @discardableResult
    func setActiveTmuxPane(_ paneId: Int) -> Bool
    
    /// Set which tmux pane receives input (send-keys) WITHOUT swapping the renderer.
    /// Used in multi-surface mode where each pane has its own observer surface.
    /// Returns true on success.
    @discardableResult
    func setActiveTmuxPaneInputOnly(_ paneId: Int) -> Bool
    
    // MARK: - Window Queries
    
    /// Number of tmux windows (0 if not in tmux mode)
    var tmuxWindowCount: Int { get }
    
    /// Info about all tmux windows
    func getAllTmuxWindows() -> [TmuxWindowInfo]
    
    /// Layout string for a window by index
    func getTmuxWindowLayout(at index: Int) -> String?
    
    /// Active tmux window ID (-1 if none)
    var tmuxActiveWindowId: Int { get }
    
    /// Focused pane ID for a window by index (from tmux's %window-pane-changed).
    /// This is the pane tmux considers focused, not the apprt-set active pane.
    /// Returns -1 if index out of bounds or no focus known.
    func tmuxWindowFocusedPaneId(at index: Int) -> Int
    
    // MARK: - Input
    
    /// Send text input (routed through Ghostty for send-keys wrapping in tmux mode)
    func sendText(_ text: String)
    
    // MARK: - Command/Response
    
    /// Send a tmux command through the viewer's command queue.
    /// Unlike fire-and-forget commands written directly to SSH stdin,
    /// this goes through Ghostty's viewer which tracks the %begin/%end
    /// response and delivers it as GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE.
    /// Returns true if the command was queued successfully.
    @discardableResult
    func sendTmuxCommand(_ command: String) -> Bool
}
