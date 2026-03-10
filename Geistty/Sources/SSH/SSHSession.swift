//
//  SSHSession.swift
//  Geistty
//
//  High-level SSH session wrapper for SwiftUI usage
//  Uses SwiftNIO-SSH with Network.framework for native iOS network monitoring
//

import Foundation
import NIOSSH
import UIKit
import os

private let logger = Logger(subsystem: "com.geistty", category: "SSHSession")

/// Delegate protocol for SSHSession events.
/// @MainActor because SSHSession is @MainActor and calls delegate methods synchronously
/// from the main thread. Without this, conforming @MainActor classes (TerminalViewModel)
/// must mark methods nonisolated + Task { @MainActor }, creating unstructured Tasks per
/// data chunk that can reorder under load — the same bug pattern fixed in Session 49
/// for NIOSSHConnectionDelegate.
@MainActor
protocol SSHSessionDelegate: AnyObject {
    func sshSessionDidConnect(_ session: SSHSession)
    func sshSession(_ session: SSHSession, didReceiveData data: Data)
    func sshSession(_ session: SSHSession, didDisconnectWithError error: Error?)
    func sshSession(_ session: SSHSession, healthDidChange health: ConnectionHealth)
}

// Default implementation for optional delegate methods
extension SSHSessionDelegate {
    func sshSession(_ session: SSHSession, healthDidChange health: ConnectionHealth) {}
}

/// tmux integration mode
enum TmuxMode {
    /// No tmux integration
    case none
    
    /// Control mode: tmux -CC with proper scrollback buffering
    case controlMode
}

/// Control mode lifecycle state
/// Tracks whether Ghostty's native tmux viewer is active.
/// Ghostty handles DCS 1000p detection, protocol parsing, and pane output routing
/// internally — we only need to know when it's active for input queueing and UI.
enum ControlModeState: Equatable, CustomStringConvertible {
    /// Not using tmux control mode (or tmux exited)
    case inactive
    
    /// Ghostty's native tmux viewer is active, ready for user input.
    /// In tmux control mode, keystrokes on stdin go directly to the active pane —
    /// no send-keys wrapping is needed.
    case active
    
    var description: String {
        switch self {
        case .inactive: return "inactive"
        case .active: return "active"
        }
    }
    
    /// Whether user input can flow through to tmux
    var isActive: Bool {
        self == .active
    }
}

/// SSH session errors
enum SSHSessionError: LocalizedError {
    case notConnected
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        }
    }
}

/// Abstraction for iOS background task management.
/// Production uses `UIApplication.shared`; tests inject a mock.
@MainActor
protocol BackgroundTaskProvider: AnyObject {
    func beginBackgroundTask(withName name: String?, expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

/// Default implementation using UIApplication (production code path)
extension UIApplication: BackgroundTaskProvider {}

/// Represents an SSH session - wraps NIOSSHConnection for SwiftUI usage
@MainActor
class SSHSession: ObservableObject, Identifiable {
    let id = UUID()
    
    // Delegate
    weak var delegate: SSHSessionDelegate? {
        didSet {
            // Flush any data that arrived before the delegate was set.
            // This covers the pre-connected session flow where SSH data
            // (including DCS 1000p) can arrive between connect() returning
            // and useExistingSession() setting the delegate.
            if delegate != nil && !earlyReceiveBuffer.isEmpty {
                let buffered = earlyReceiveBuffer
                earlyReceiveBuffer.removeAll()
                logger.info("Flushing \(buffered.count) early-received chunks (\(buffered.reduce(0) { $0 + $1.count })B) to new delegate")
                for chunk in buffered {
                    delegate?.sshSession(self, didReceiveData: chunk)
                }
            }
        }
    }
    
    /// Buffer for data received before delegate is set (pre-connected session flow)
    private var earlyReceiveBuffer: [Data] = []
    
    // Connection
    private var connection: NIOSSHConnection?
    
    // Connection parameters (stored after connect)
    private(set) var host: String = ""
    private(set) var port: Int = 22
    private(set) var username: String = ""
    
    // Stored credentials for reconnect (in memory only, never persisted)
    private var storedAuthMethod: SSHAuthMethod?
    private var storedProfile: ConnectionProfile?
    private var storedCredential: SSHCredential?
    
    /// Public accessor for the profile ID (for File Provider refresh signaling)
    var profileId: String? {
        storedProfile?.id.uuidString
    }
    
    // Reconnection state
    @Published private(set) var isReconnecting: Bool = false
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 3
    
    // Background task state — protects detach+cleanup when iOS backgrounds the app.
    // Without this, iOS suspends the app ~5s after backgrounding, killing the TCP
    // socket before the tmux detach-client command can complete. The background task
    // buys ~30s to finish the detach handshake and close the SSH channel cleanly.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    /// Tracks the 5-second safety timer that ends the background task.
    /// Stored so it can be cancelled on rapid bg/fg cycling to prevent
    /// a stale timer from ending a *new* background task prematurely.
    private var backgroundSafetyTimerTask: Task<Void, Never>?
    
    /// Injectable background task provider — defaults to UIApplication.shared.
    /// Tests inject a mock to verify background task lifecycle without a running app.
    var backgroundTaskProvider: BackgroundTaskProvider = UIApplication.shared
    
    // tmux options
    private var useTmux: Bool = false
    private var tmuxSessionName: String?
    private var tmuxMode: TmuxMode = .none
    
    /// tmux Session Manager for multi-pane state management
    /// Access this to get session/window/pane info and route output to surfaces
    private(set) var tmuxSessionManager: TmuxSessionManager?
    
    /// Notification observers for Ghostty's tmux action callbacks
    private var tmuxNotificationObservers: [NSObjectProtocol] = []
    
    /// Ghostty surface for tmux pane switching.
    /// Set by TerminalViewModel after creating the surface.
    /// Used to call setActiveTmuxPane() when TMUX_STATE_CHANGED fires.
    weak var ghosttySurface: Ghostty.SurfaceView? {
        didSet {
            logger.debug("ghosttySurface set: \(ghosttySurface != nil ? "non-nil" : "nil"), controlModeState=\(controlModeState), viewerReady=\(viewerReady)")
            // If control mode is already active AND the viewer is ready when the surface
            // gets wired, activate the first pane immediately. This handles the race where
            // TMUX_READY fired before ghosttySurface was set.
            if ghosttySurface != nil && controlModeState.isActive && viewerReady {
                logger.info("ghosttySurface set while viewer ready, attempting pane activation")
                activateFirstTmuxPane()
            }
        }
    }
    
    /// Protocol-typed accessor for the tmux surface.
    /// In production, returns `ghosttySurface`. In tests, returns `tmuxSurfaceOverride`
    /// (a MockTmuxSurface) if set. This enables testing activateFirstTmuxPane(),
    /// flushPendingInput(), and notification handlers without a real GhosttyKit surface.
    var tmuxSurface: (any TmuxSurfaceProtocol)? {
        #if DEBUG
        if let override = tmuxSurfaceOverride { return override }
        #endif
        return ghosttySurface
    }
    
    #if DEBUG
    /// Test-only override for the tmux surface. Set this to a MockTmuxSurface
    /// to test lifecycle methods without a real Ghostty surface.
    var tmuxSurfaceOverride: (any TmuxSurfaceProtocol)?
    #endif
    
    /// Whether we've successfully activated a tmux pane for rendering.
    /// Prevents redundant activation calls on subsequent state changes.
    private(set) var tmuxPaneActivated: Bool = false
    
    /// The tmux pane ID that the Ghostty renderer is displaying.
    /// Set when activateFirstTmuxPane() calls ghostty_surface_tmux_set_active_pane().
    /// Cleared on tmux exit/disconnect. Ghostty's Zig-side Termio.queueWrite()
    /// uses the viewer's active_pane_id (set via the same C API call) for
    /// send-keys wrapping — this Swift property is for UI state tracking only.
    private(set) var activeTmuxPaneId: Int? = nil
    
    /// Whether the tmux viewer's initial command queue has drained.
    /// Set to true when GHOSTTY_ACTION_TMUX_READY fires (viewer.zig emits .ready
    /// after all startup commands complete). Reset on disconnect/tmux exit.
    ///
    /// This gates user input: when false, input is queued in pendingInputQueue
    /// to prevent interleaving with viewer commands. When true,
    /// activateFirstTmuxPane() is called which sets activeTmuxPaneId and
    /// flushes pending input with proper send-keys wrapping.
    private(set) var viewerReady: Bool = false
    
    /// Control mode lifecycle state
    /// Ghostty's native tmux viewer handles DCS 1000p detection and protocol parsing.
    /// This state tracks whether the viewer is active (from TMUX_STATE_CHANGED action).
    private(set) var controlModeState: ControlModeState = .inactive
    
    /// Snapshot of session state captured when the app goes to background.
    /// Tells `appDidBecomeActive()` that we had an active session and should reconnect.
    /// Also used by `connectionDidClose` to suppress the disconnect-navigation flow
    /// (the SSH connection dying during background is expected, not an error).
    ///
    /// Replaces the old `isDetachingForBackground` flag. The old approach sent
    /// `detach-client` on background, which triggered `%exit` → surface teardown →
    /// `quit_timer` → process termination before reconnection could run. The new
    /// approach simply lets iOS suspend the process — the SSH connection dies from
    /// neglect, tmux session persists server-side, and we reconnect on foreground.
    struct BackgroundSessionState {
        let controlModeWasActive: Bool
        let tmuxSessionName: String?
    }
    private(set) var backgroundState: BackgroundSessionState?
    
    /// Legacy accessor — tests and `handleSplitTreeChange` still check this.
    /// Returns true when `backgroundState` is non-nil.
    var isDetachingForBackground: Bool {
        backgroundState != nil
    }
    
    /// Whether disconnect notifications should be suppressed.
    /// True during background detach (expected TCP death) or active reconnect
    /// (old connection teardown). The stale connection guard in `connectionDidClose`
    /// is separate — it operates on object identity, not flag state.
    private var shouldSuppressDisconnectNotification: Bool {
        isDetachingForBackground || isReconnecting
    }
    
    /// Session name discovery state for geistty-N auto-naming.
    /// When no custom tmux session name is set, we query `tmux list-sessions`
    /// before entering control mode. This state tracks that pre-control-mode query.
    private enum SessionDiscoveryState {
        /// Not performing session discovery (custom name set, or already resolved)
        case idle
        /// Waiting for `tmux list-sessions` response.
        /// Stores the accumulated buffer and the nonce-based end marker for this query,
        /// so we match only the actual sentinel output and not the echoed command. See #4.
        case querying(buffer: String, endMarker: String)
        /// Discovery complete, `exec tmux -CC` sent, waiting for DCS 1000p to arrive.
        /// All data in this state is suppressed (not forwarded to Ghostty) to prevent
        /// the shell echo of the exec command from rendering on screen. See #68.
        case awaitingControlMode
    }
    private var sessionDiscoveryState: SessionDiscoveryState = .idle
    
    /// Single deadline timer for the entire tmux attach flow (#68, H6).
    /// Covers both session discovery (.querying) and DCS 1000p wait (.awaitingControlMode).
    /// Started once in attachToTmuxNow(), cancelled when DCS 1000p arrives.
    /// If it fires, checks the current state and falls back appropriately.
    private var tmuxAttachTimer: Task<Void, Never>?
    
    // Queue of input data waiting to be sent once control mode activates
    // This prevents input from going to tmux's command prompt before the shell is ready
    private(set) var pendingInputQueue: [Data] = []
    
    // State
    @Published var state: NIOSSHState = .disconnected
    @Published var lastError: Error?
    
    /// Connection health - reflects network path monitoring from NIOSSHConnection
    @Published private(set) var connectionHealth: ConnectionHealth = .healthy
    
    // Terminal dimensions
    private var terminalCols: Int = 80
    private var terminalRows: Int = 24
    
    // Serial write queue — ensures keystrokes are sent in order.
    // performWrite() yields to this stream; a single consumer Task
    // processes writes sequentially, preventing out-of-order delivery
    // that occurred with the previous Task-per-keystroke approach.
    private var writeStream: AsyncStream<(command: Data, original: Data)>?
    private var writeContinuation: AsyncStream<(command: Data, original: Data)>.Continuation?
    private var writeConsumerTask: Task<Void, Never>?
    
    init() {
        // Initial setup — no previous consumer exists, so we can create directly
        let (stream, continuation) = AsyncStream<(command: Data, original: Data)>.makeStream()
        writeStream = stream
        writeContinuation = continuation
        
        writeConsumerTask = Task { [weak self] in
            for await (command, original) in stream {
                guard let self = self, !Task.isCancelled else { break }
                await self.executeWrite(command, originalData: original)
            }
        }
    }
    
    deinit {
        // #58: Clean up async resources that disconnect() may not have cleared.
        // Without this, the AsyncStream continuation and background tasks leak.
        writeContinuation?.finish()
        writeConsumerTask?.cancel()
        backgroundSafetyTimerTask?.cancel()
        tmuxAttachTimer?.cancel()
        
        // NotificationCenter.removeObserver is thread-safe, so this is safe
        // even though @MainActor deinit may run on an arbitrary thread.
        // Prevents observer leaks if disconnect() was never called.
        let observers = tmuxNotificationObservers
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    /// The TERM type to use - xterm-256color is universally supported
    /// Note: xterm-ghostty would be ideal but most servers don't have the terminfo
    private static let termType = "xterm-256color"
    
    // MARK: - Connect Methods
    
    /// Common setup before connection
    private func prepareConnection(
        host: String,
        port: Int,
        username: String,
        useTmux: Bool,
        tmuxSessionName: String?
    ) -> NIOSSHConnection {
        self.host = host
        self.port = port
        self.username = username
        self.useTmux = useTmux
        self.tmuxSessionName = tmuxSessionName
        self.tmuxMode = useTmux ? .controlMode : .none
        
        let conn = NIOSSHConnection(host: host, port: port, username: username)
        conn.cols = terminalCols
        conn.rows = terminalRows
        conn.delegate = self
        connection = conn
        return conn
    }
    
    /// Common setup after successful connection
    private func finalizeConnection() {
        // Reset reconnect attempts on successful connection
        reconnectAttempts = 0
        
        // Initialize session manager if using control mode
        logger.debug("finalizeConnection: tmuxMode=\(tmuxMode)")
        if tmuxMode == .controlMode {
            setupTmuxSessionManager()
        }
        
        // Inject shell initialization for best terminal experience
        injectTerminalSetup()
    }
    
    /// Connect to the SSH server with password authentication
    func connect(host: String, port: Int, username: String, password: String, useTmux: Bool = false, tmuxSessionName: String? = nil) async throws {
        let conn = prepareConnection(
            host: host, port: port, username: username,
            useTmux: useTmux, tmuxSessionName: tmuxSessionName
        )
        
        // Store auth method for reconnect (in memory only)
        self.storedAuthMethod = .password(password)
        self.storedProfile = nil
        self.storedCredential = nil
        
        try await conn.connect(password: password)
        finalizeConnection()
    }
    
    /// Connect using a saved connection profile and credentials
    /// - Note: Control mode is enabled by default for testing
    func connect(profile: ConnectionProfile, credential: SSHCredential) async throws {
        let conn = prepareConnection(
            host: profile.host, port: profile.port, username: profile.username,
            useTmux: profile.useTmux, tmuxSessionName: profile.tmuxSessionName
        )
        
        // Store profile and credential for reconnect (in memory only)
        self.storedProfile = profile
        self.storedCredential = credential
        
        // Build auth method from credential
        let authMethod = try buildAuthMethod(from: credential)
        self.storedAuthMethod = authMethod
        
        try await conn.connect(authMethod: authMethod)
        
        // Mark profile as recently connected
        ConnectionProfileManager.shared.markConnected(profile)
        
        finalizeConnection()
    }
    
    /// Build an SSHAuthMethod from an SSHCredential.
    /// Key parsing is delegated to SSHKeyParser (Sources/Auth/SSHKeyParser.swift).
    /// Secure Enclave keys arrive pre-built as NIOSSHPrivateKey and bypass parsing.
    private func buildAuthMethod(from credential: SSHCredential) throws -> SSHAuthMethod {
        switch credential.authType {
        case .password(let password):
            return .password(password)
            
        case .privateKey(let path, let passphrase):
            let keyData = try Data(contentsOf: URL(fileURLWithPath: path))
            let privateKey = try SSHKeyParser.parsePrivateKey(keyData, passphrase: passphrase)
            return .publicKey(privateKey: privateKey)
            
        case .privateKeyData(let keyData, let passphrase):
            let privateKey = try SSHKeyParser.parsePrivateKey(keyData, passphrase: passphrase)
            return .publicKey(privateKey: privateKey)
            
        case .sshPrivateKey(let nioKey):
            // Pre-built key (Secure Enclave) — no parsing needed
            return .publicKey(privateKey: nioKey)
        }
    }
    
    // MARK: - tmux Control Mode Setup
    
    /// Set up the tmux session manager for control mode.
    /// Ghostty's native tmux viewer handles DCS 1000p detection, protocol parsing,
    /// and pane output routing internally. The session manager coordinates iOS-specific
    /// UI concerns: surface management, split trees, window picker, detach on background.
    ///
    /// Data flow with Ghostty's native tmux:
    /// SSH → SSHSession.handleReceivedData → delegate.didReceiveData → Ghostty.writeOutput
    ///   → VT parser detects DCS 1000p → tmux viewer activates
    ///   → viewer parses %output/%layout-change/etc → routes to per-pane Terminals
    ///   → TMUX_STATE_CHANGED action → NotificationCenter → TmuxSessionManager
    private func setupTmuxSessionManager() {
        logger.info("Setting up tmux session manager (native Ghostty tmux)")
        
        let manager = TmuxSessionManager()
        tmuxSessionManager = manager
        
        // Provide the write function for fire-and-forget tmux commands.
        // In control mode, commands written to stdin go directly to tmux.
        manager.setupWithDirectWrite { [weak self] command in
            Task { @MainActor in
                self?.writeControlCommand(command)
            }
        }
        
        // Observe Ghostty's native tmux notifications.
        // These fire when Ghostty's internal tmux viewer detects state changes
        // via the TMUX_STATE_CHANGED and TMUX_EXIT action callbacks.
        observeTmuxNotifications()
    }
    
    /// Register for Ghostty's tmux state notifications.
    /// TMUX_STATE_CHANGED fires when the tmux viewer activates or pane state changes.
    /// TMUX_EXIT fires when the tmux control mode session ends.
    /// TMUX_READY fires when the viewer's startup command queue drains.
    ///
    /// H8 fix: Notifications are posted with the surface as `object`. We observe
    /// with `object: nil` (since ghosttySurface may not be set yet) but filter
    /// in the handler body to only process notifications for our surface.
    /// This prevents cross-window interference on multi-window iPad.
    private func observeTmuxNotifications() {
        // Remove any existing observers first (idempotent)
        removeTmuxNotificationObservers()
        
        let stateObserver = NotificationCenter.default.addObserver(
            forName: .tmuxStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else {
                return
            }
            
            // H8: Only process notifications for our surface (multi-window safety)
            // If notification carries a surface, require it matches ours.
            // If our surface is nil (teardown), the === check fails → skip.
            if let notifSurface = notification.object as? Ghostty.SurfaceView {
                guard notifSurface === self.ghosttySurface else { return }
            }
            
            let windowCount = notification.userInfo?[TmuxNotificationKey.windowCount] as? UInt ?? 0
            let paneCount = notification.userInfo?[TmuxNotificationKey.paneCount] as? UInt ?? 0
            
            logger.info("tmux state changed: \(windowCount) windows, \(paneCount) panes, current state=\(self.controlModeState)")
            
            if self.controlModeState == .inactive {
                // First state change — control mode just activated
                self.controlModeState = .active
                logger.info("Control mode activated via TMUX_STATE_CHANGED")
                self.tmuxSessionManager?.controlModeActivated()
                // NOTE: Do NOT activate pane or flush input here.
                // Wait for TMUX_READY which fires after the viewer's command queue drains.
                // Activating here would cause user input to interleave with viewer commands.
            }
            
            // Subsequent state changes update pane/window info
            self.tmuxSessionManager?.handleTmuxStateChanged(
                windowCount: Int(windowCount),
                paneCount: Int(paneCount)
            )
            
            // If viewerReady was already set (subsequent state changes after initial ready),
            // activate pane for any new panes that may have appeared.
            if self.viewerReady {
                self.activateFirstTmuxPane()
            }
        }
        
        let exitObserver = NotificationCenter.default.addObserver(
            forName: .tmuxExited,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            // H8: Only process notifications for our surface (multi-window safety)
            // If notification carries a surface, require it matches ours.
            // If our surface is nil (teardown), the === check fails → skip.
            if let notifSurface = notification.object as? Ghostty.SurfaceView {
                guard notifSurface === self.ghosttySurface else { return }
            }
            
            // Extract the exit reason forwarded from Ghostty's tmux viewer.
            // Known reasons: "detached" (voluntary), "server-exited" (crash),
            // "" (empty, e.g. session destroyed).
            let reason = notification.userInfo?[TmuxNotificationKey.reason] as? String ?? ""
            logger.info("tmux control mode exited via TMUX_EXIT, reason: \(reason.isEmpty ? "(none)" : reason)")
            
            self.controlModeState = .inactive
            self.tmuxPaneActivated = false
            self.activeTmuxPaneId = nil
            self.viewerReady = false
            
            // End background task if one is active — viewer teardown is complete.
            self.endBackgroundTaskIfNeeded()
            
            if self.isDetachingForBackground {
                // This TMUX_EXIT was triggered by the C1 ST (0x9C) sent in
                // appDidBecomeActive() to exit the stale DCS passthrough.
                // Do a lightweight reset that preserves the primary surface
                // so attemptReconnect() can reuse the existing manager.
                logger.info("C1 ST triggered viewer teardown — preserving surfaces for reattach")
                self.tmuxSessionManager?.prepareForReattach()
            } else {
                // Normal tmux exit (user ran `exit`, server killed session, etc.)
                // Nuclear teardown — destroy all surfaces and reset state.
                // Forward the reason so TmuxSessionManager can distinguish
                // voluntary detach from involuntary exit.
                self.tmuxSessionManager?.controlModeExited(reason: reason.isEmpty ? nil : reason)
            }
        }
        
        let readyObserver = NotificationCenter.default.addObserver(
            forName: .tmuxReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            // H8: Only process notifications for our surface (multi-window safety)
            // If notification carries a surface, require it matches ours.
            // If our surface is nil (teardown), the === check fails → skip.
            if let notifSurface = notification.object as? Ghostty.SurfaceView {
                guard notifSurface === self.ghosttySurface else { return }
            }
            
            logger.info("tmux viewer startup complete (TMUX_READY), safe to send user input")
            self.viewerReady = true
            
            // Tell the session manager the viewer is ready — this flushes any
            // Swift-side commands (e.g., refresh-client) that were queued during
            // the viewer's startup capture-pane sequence.
            self.tmuxSessionManager?.viewerBecameReady()
            
            // NOW it's safe to activate the first pane and flush pending input.
            // The viewer's command queue has drained — no risk of interleaving.
            self.activateFirstTmuxPane()
        }
        
        let commandResponseObserver = NotificationCenter.default.addObserver(
            forName: .tmuxCommandResponse,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            // H8: Only process notifications for our surface
            if let notifSurface = notification.object as? Ghostty.SurfaceView {
                guard notifSurface === self.ghosttySurface else { return }
            }
            
            let content = notification.userInfo?[TmuxNotificationKey.content] as? String ?? ""
            let isError = notification.userInfo?[TmuxNotificationKey.isError] as? Bool ?? false
            
            self.tmuxSessionManager?.handleCommandResponse(content: content, isError: isError)
        }
        
        let activeWindowObserver = NotificationCenter.default.addObserver(
            forName: .tmuxActiveWindowChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            // H8: Only process notifications for our surface
            if let notifSurface = notification.object as? Ghostty.SurfaceView {
                guard notifSurface === self.ghosttySurface else { return }
            }
            
            guard let windowId = notification.userInfo?[TmuxNotificationKey.windowId] as? UInt32 else {
                return
            }
            
            self.tmuxSessionManager?.handleActiveWindowChanged(windowId: Int(windowId))
        }
        
        let sessionRenamedObserver = NotificationCenter.default.addObserver(
            forName: .tmuxSessionRenamed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            if let notifSurface = notification.object as? Ghostty.SurfaceView {
                guard notifSurface === self.ghosttySurface else { return }
            }
            
            guard let name = notification.userInfo?[TmuxNotificationKey.name] as? String else {
                return
            }
            
            self.tmuxSessionManager?.handleSessionRenamed(name: name)
        }
        
        let focusedPaneChangedObserver = NotificationCenter.default.addObserver(
            forName: .tmuxFocusedPaneChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            if let notifSurface = notification.object as? Ghostty.SurfaceView {
                guard notifSurface === self.ghosttySurface else { return }
            }
            
            guard let windowId = notification.userInfo?[TmuxNotificationKey.windowId] as? UInt32,
                  let paneId = notification.userInfo?[TmuxNotificationKey.paneId] as? UInt32 else {
                return
            }
            
            self.tmuxSessionManager?.handleFocusedPaneChanged(windowId: windowId, paneId: paneId)
        }
        
        let subscriptionChangedObserver = NotificationCenter.default.addObserver(
            forName: .tmuxSubscriptionChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            if let notifSurface = notification.object as? Ghostty.SurfaceView {
                guard notifSurface === self.ghosttySurface else { return }
            }
            
            guard let name = notification.userInfo?[TmuxNotificationKey.name] as? String,
                  let value = notification.userInfo?[TmuxNotificationKey.value] as? String else {
                return
            }
            
            self.tmuxSessionManager?.handleSubscriptionChanged(name: name, value: value)
        }
        
        tmuxNotificationObservers = [stateObserver, exitObserver, readyObserver, commandResponseObserver, activeWindowObserver, sessionRenamedObserver, focusedPaneChangedObserver, subscriptionChangedObserver]
    }
    
    /// Remove tmux notification observers
    private func removeTmuxNotificationObservers() {
        for observer in tmuxNotificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        tmuxNotificationObservers.removeAll()
    }
    
    /// Flush pending input queue after control mode activates and pane is set.
    /// Routes through Ghostty's sendText() so user input gets Zig-side send-keys wrapping.
    /// Falls back to writeFromGhostty() for non-text data.
    private func flushPendingInput() {
        guard !pendingInputQueue.isEmpty else { return }
        
        logger.info("Flushing \(pendingInputQueue.count) queued input chunks")
        tmuxSessionManager?.clearPendingInputDisplay()
        
        for data in pendingInputQueue {
            // Try to route through Ghostty for proper send-keys wrapping
            if let text = String(data: data, encoding: .utf8), let surface = tmuxSurface {
                surface.sendText(text)
            } else {
                // Non-text data or no surface — write directly (best effort)
                writeFromGhostty(data)
            }
        }
        pendingInputQueue.removeAll()
    }
    
    /// Switch the Metal renderer to display the first tmux pane's Terminal.
    ///
    /// When Ghostty enters tmux control mode, the viewer creates per-pane Terminal
    /// instances and routes %output data to them. But the renderer still points at
    /// the main (empty) Terminal. We must call ghostty_surface_tmux_set_active_pane()
    /// to swap the renderer's terminal pointer to the pane Terminal.
    ///
    /// This is called from two places:
    /// 1. The TMUX_STATE_CHANGED notification handler (normal path)
    /// 2. The ghosttySurface didSet (fallback for race condition where the
    ///    notification fired before the surface was wired)
    private func activateFirstTmuxPane() {
        guard !tmuxPaneActivated else {
            logger.debug("tmux pane already activated, skipping")
            return
        }
        
        guard let surface = tmuxSurface else {
            logger.info("activateFirstTmuxPane: tmuxSurface is nil, will retry when set")
            return
        }
        
        let paneCount = surface.tmuxPaneCount
        logger.info("activateFirstTmuxPane: paneCount=\(paneCount)")
        
        guard paneCount > 0 else {
            logger.info("activateFirstTmuxPane: no panes yet, will retry on next state change")
            return
        }
        
        let paneIds = surface.getTmuxPaneIds()
        logger.info("activateFirstTmuxPane: paneIds=\(paneIds)")
        
        guard let firstPaneId = paneIds.first else {
            logger.warning("activateFirstTmuxPane: getTmuxPaneIds returned empty despite paneCount=\(paneCount)")
            return
        }
        
        let success = surface.setActiveTmuxPane(firstPaneId)
        logger.info("activateFirstTmuxPane: set active pane to %\(firstPaneId): \(success)")
        
        if success {
            tmuxPaneActivated = true
            activeTmuxPaneId = firstPaneId
            logger.info("activateFirstTmuxPane: activeTmuxPaneId set to %\(firstPaneId)")
            
            // Now that we have a pane ID, flush any queued input with send-keys wrapping.
            // This must happen AFTER activeTmuxPaneId is set so writeFromGhostty()
            // correctly wraps user input instead of sending raw bytes to tmux stdin.
            flushPendingInput()
        }
    }
    
    /// Inject commands to set up the terminal environment
    /// This handles cases where the SSH server doesn't accept setenv
    /// Note: Some restricted shells (like test servers) don't support these commands,
    /// so we make this optional and non-disruptive
    private func injectTerminalSetup() {
        // In control mode, we skip env var injection and go straight to tmux
        // The tmux attach command is sent immediately - the shell will execute it
        // when it's ready. We don't need delays because:
        // 1. SSH channel is already open with a PTY
        // 2. Commands are queued by the shell
        // 3. We wait for %session-changed to know tmux is ready
        if tmuxMode == .controlMode {
            attachToTmuxNow()
            return
        }
        
        // For legacy mode or no tmux, use the traditional delay-based approach
        // to let the shell initialize and show MOTD first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.injectEnvironmentVariables()
        }
        
        if useTmux {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.attachToTmuxNow()
            }
        }
    }
    
    /// Inject environment variables for optimal TUI app experience
    /// These help apps like Yazi, kew, aichat, browsh detect terminal capabilities
    /// Uses a single-line command that suppresses output and avoids shell history
    private func injectEnvironmentVariables() {
        // Truly silent injection:
        // - Space prefix: avoids bash/zsh history (HISTCONTROL=ignorespace)
        // - eval "...": single command execution
        // - All on one line with semicolons
        // - 2>/dev/null suppresses any errors
        // - Uses POSIX-compatible syntax for maximum shell compatibility
        // NOTE: No 'clear' - it interferes with session restore
        let envSetup = " eval 'export COLORTERM=truecolor TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION=1.0.0; [ -z \"$LANG\" ] && export LANG=en_US.UTF-8' 2>/dev/null\n"
        if let data = envSetup.data(using: .utf8) {
            write(data)
        }
    }
    
    /// Auto-attach to or create a tmux session.
    ///
    /// If the user set a custom `tmuxSessionName`, uses it directly.
    /// Otherwise, queries existing sessions to find an unattached `geistty-N`
    /// session to reattach to, or creates the next `geistty-<N+1>`.
    ///
    /// The query happens as a raw shell command before entering control mode:
    /// 1. Send `tmux list-sessions ...` to the shell
    /// 2. Intercept the response in `handleReceivedData()` (via `sessionDiscoveryState`)
    /// 3. Parse the response with `TmuxSessionNameResolver`
    /// 4. Send `exec tmux -CC new-session -A -s <resolved-name>`
    private func attachToTmuxNow() {
        guard tmuxMode == .controlMode else { return }
        
        // Start a single deadline timer for the entire attach flow.
        // Covers both discovery (.querying) and DCS 1000p wait (.awaitingControlMode).
        // If the timer fires, it checks which phase we're stuck in and acts accordingly.
        startTmuxAttachTimer()
        
        // If the user specified a custom session name, skip discovery
        if let customName = tmuxSessionName, !customName.isEmpty {
            logger.info("Using custom tmux session name: \(customName)")
            // #68: Suppress shell echo until DCS 1000p arrives
            sessionDiscoveryState = .awaitingControlMode
            sendTmuxAttachCommand(sessionName: customName)
            return
        }
        
        // Begin session discovery: query existing sessions
        logger.info("Starting geistty-N session discovery")
        let (query, marker) = TmuxSessionNameResolver.makeQueryCommand()
        sessionDiscoveryState = .querying(buffer: "", endMarker: marker)
        if let data = query.data(using: .utf8) {
            writeControlCommand(data)
        }
    }
    
    /// Send the actual tmux attach command after session name is resolved
    private func sendTmuxAttachCommand(sessionName: String) {
        // Use control mode (-CC) for proper scrollback access
        // exec replaces the shell with tmux
        // Shell-escape the session name to prevent command injection
        let escapedName = sessionName.replacingOccurrences(of: "'", with: "'\\''")
        let command = "exec tmux -CC new-session -A -s '\(escapedName)'\n"
        logger.info("Attaching to tmux in control mode: \(sessionName)")
        // Write directly to connection — don't go through self.write() which would queue it!
        if let data = command.data(using: .utf8) {
            writeControlCommand(data)
        }
    }
    
    /// Single deadline timer for the entire tmux attach flow (H6 + #68).
    /// Covers both discovery (.querying) and DCS 1000p wait (.awaitingControlMode).
    /// If the timer fires in either phase, falls back to .idle so data flows
    /// normally. 10s is generous — discovery + exec + tmux startup typically < 2s.
    private func startTmuxAttachTimer() {
        tmuxAttachTimer?.cancel()
        tmuxAttachTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            switch self.sessionDiscoveryState {
            case .querying:
                logger.warning("Tmux attach timed out during discovery after 10s, falling back to idle")
                self.sessionDiscoveryState = .idle
            case .awaitingControlMode:
                logger.warning("Tmux attach timed out awaiting DCS 1000p after 10s, falling back to idle")
                self.sessionDiscoveryState = .idle
            case .idle:
                break
            }
        }
    }
    
    // MARK: - tmux Integration
    
    /// Check if this session is using tmux
    var isTmuxSession: Bool {
        return useTmux
    }
    
    /// Check if this session is using tmux control mode
    var isTmuxControlMode: Bool {
        return tmuxMode == .controlMode
    }
    
    /// Resize the PTY
    func resize(cols: Int, rows: Int) {
        terminalCols = cols
        terminalRows = rows
        connection?.resizePTY(cols: cols, rows: rows)
    }
    
    /// Write user input data to the SSH channel.
    ///
    /// Called as a fallback from `TerminalContainerView.send(text:)` when no Ghostty
    /// surface is available. Normally, user input is routed through Ghostty's
    /// `ghostty_surface_text()` → `queueWrite()` → Zig send-keys wrapping →
    /// `writeFromGhostty()`, which handles tmux control mode automatically.
    ///
    /// This direct path does NOT apply tmux send-keys wrapping. In tmux control
    /// mode, data written here would be interpreted as raw tmux commands. This is
    /// acceptable because this path is only used when there's no surface (pre-
    /// connection, post-disconnect), and we queue the data for later anyway.
    func write(_ data: Data) {
        if let str = String(data: data, encoding: .utf8) {
            logger.debug("SSHSession.write: \(data.count) bytes: \(str.prefix(20))")
        }
        
        // Check connection health — if stale/dead, queue instead of sending
        if !connectionHealth.isHealthy {
            logger.debug("Connection unhealthy (\(String(describing: connectionHealth))), queueing \(data.count) bytes of input")
            pendingInputQueue.append(data)
            updatePendingInputDisplay()
            return
        }
        
        // If we're in control mode, queue the input. Without a Ghostty surface,
        // we can't apply send-keys wrapping, so raw data must not reach tmux stdin.
        // It will be flushed through Ghostty's path when the surface is ready.
        if tmuxMode == .controlMode && controlModeState.isActive {
            logger.info("write() in control mode without Ghostty path, queueing \(data.count) bytes")
            pendingInputQueue.append(data)
            updatePendingInputDisplay()
            return
        }
        
        // If we're in control mode but tmux isn't ready yet, queue the input.
        if tmuxMode == .controlMode && !controlModeState.isActive {
            logger.info("Control mode pending (state=\(controlModeState)), queueing \(data.count) bytes of input")
            pendingInputQueue.append(data)
            updatePendingInputDisplay()
            return
        }
        
        performWrite(data, originalData: data)
    }
    
    // MARK: - Ghostty write callback
    
    /// Write data from Ghostty's write_callback directly to SSH.
    ///
    /// Ghostty's External backend sends ALL outbound data through its write_callback.
    /// After the Zig-side send-keys routing (Termio.queueWrite → viewer.sendKeys),
    /// ALL data arriving here is already properly formatted:
    /// - Viewer commands: "list-windows\n", "capture-pane ...\n"
    /// - User input: "send-keys -H -t %2 6C 73 0D\n" (wrapped by Zig)
    ///
    /// The Swift side just passes everything through to SSH. No heuristics,
    /// no wrapping, no queueing needed.
    ///
    /// Connection health checks still apply — if the connection is dead, there's
    /// nowhere to send data regardless.
    func writeFromGhostty(_ data: Data) {
        // Connection health check still applies
        if !connectionHealth.isHealthy {
            logger.debug("Connection unhealthy, dropping Ghostty write of \(data.count) bytes")
            return
        }
        
        performWrite(data, originalData: data)
    }
    
    /// Set up the serial write stream and consumer task.
    /// Called from init() and after reconnect to ensure a fresh stream.
    ///
    /// This method is async because it awaits the previous consumer task's
    /// completion before starting a new one. Without this, two consumer tasks
    /// can briefly coexist, processing writes concurrently and breaking ordering.
    private func setupWriteStream() async {
        // Finish the stream first so the consumer's `for await` terminates
        writeContinuation?.finish()
        // Cancel as a signal, then await to guarantee the old consumer is done
        writeConsumerTask?.cancel()
        await writeConsumerTask?.value
        
        let (stream, continuation) = AsyncStream<(command: Data, original: Data)>.makeStream()
        writeStream = stream
        writeContinuation = continuation
        
        writeConsumerTask = Task { [weak self] in
            for await (command, original) in stream {
                guard let self = self, !Task.isCancelled else { break }
                await self.executeWrite(command, originalData: original)
            }
        }
    }
    
    /// Perform the actual write with error handling.
    /// Enqueues the write into the serial stream for ordered delivery.
    /// - Parameters:
    ///   - command: The data to write (may be tmux-wrapped command)
    ///   - originalData: The original user input (for queueing on failure)
    private func performWrite(_ command: Data, originalData: Data) {
        guard connection != nil else {
            // Skip queueing for control commands (empty originalData sentinel)
            guard !originalData.isEmpty else {
                logger.warning("⚠️ Control command dropped — no connection")
                return
            }
            logger.warning("⚠️ No connection for write, queueing")
            pendingInputQueue.append(originalData)
            updatePendingInputDisplay()
            return
        }
        
        writeContinuation?.yield((command: command, original: originalData))
    }
    
    /// Execute a single write to the SSH connection (called serially by consumer task).
    private func executeWrite(_ command: Data, originalData: Data) async {
        guard let connection = connection else {
            // Skip queueing for control commands (empty originalData sentinel)
            guard !originalData.isEmpty else { return }
            await MainActor.run {
                self.pendingInputQueue.append(originalData)
                self.updatePendingInputDisplay()
            }
            return
        }
        
        do {
            try await connection.writeAsync(command)
            // Success! If we were stale, NIOSSHConnection will mark us healthy
        } catch {
            // Write failed — queue the ORIGINAL data (not the tmux command)
            // Skip queueing for control commands (empty originalData sentinel)
            logger.error("❌ Write failed: \(error.localizedDescription)")
            guard !originalData.isEmpty else {
                logger.warning("⚠️ Control command write failed (not queued): \(error.localizedDescription)")
                return
            }
            logger.error("Queueing \(originalData.count) bytes of user input")
            await MainActor.run {
                self.pendingInputQueue.append(originalData)
                self.updatePendingInputDisplay()
                
                // Update health state if not already dead
                if self.connectionHealth.isHealthy || self.connectionHealth != .dead(reason: error.localizedDescription) {
                    self.connectionHealth = .dead(reason: error.localizedDescription)
                    self.delegate?.sshSession(self, healthDidChange: self.connectionHealth)
                }
            }
        }
    }
    
    /// Update the visual display of pending input using preedit
    private func updatePendingInputDisplay() {
        // Build a displayable string from the queue (filter out control chars)
        let displayText = pendingInputQueue
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined()
            .filter { !$0.isASCII || ($0.asciiValue ?? 0) >= 32 || $0 == "\n" || $0 == "\t" }
        
        logger.info("📝 updatePendingInputDisplay: '\(displayText)' tmuxSessionManager=\(tmuxSessionManager != nil)")
        tmuxSessionManager?.displayPendingInput(displayText)
    }
    
    /// Write a control command (not user input) to the connection.
    /// Routed through the serial write stream to prevent races with user input.
    /// Control commands use empty `originalData` so they are NOT queued on failure
    /// (they're ephemeral — replaying stale control commands after reconnect is wrong).
    /// - Parameter command: The command data to write
    private func writeControlCommand(_ command: Data) {
        // Log what we're sending
        if let str = String(data: command, encoding: .utf8) {
            logger.info("📤 writeControlCommand: \(str.prefix(100))")
        }
        
        // Route through serial stream with empty originalData sentinel
        // (performWrite checks connection; if nil, empty data is harmless to queue)
        performWrite(command, originalData: Data())
    }
    
    /// Convenience overload for string commands
    private func writeControlCommand(_ command: String) {
        logger.info("📤 writeControlCommand(String): \(command.prefix(100))")
        guard let data = command.data(using: .utf8) else { return }
        writeControlCommand(data)
    }
    
    /// Disconnect the session
    func disconnect() {
        controlModeState = .inactive
        tmuxPaneActivated = false
        activeTmuxPaneId = nil
        viewerReady = false
        backgroundState = nil
        sessionDiscoveryState = .idle
        tmuxAttachTimer?.cancel()
        tmuxAttachTimer = nil
        backgroundSafetyTimerTask?.cancel()
        backgroundSafetyTimerTask = nil
        pendingInputQueue.removeAll()
        removeTmuxNotificationObservers()
        
        // End any background task — we're explicitly disconnecting,
        // no need to keep the background task running
        endBackgroundTaskIfNeeded()
        
        // Send clean detach before tearing down, so tmux session survives
        // on the server and can be reattached later (like iTerm2's behavior).
        // H5 fix: detach MUST happen before write queue teardown, otherwise
        // the detach command will never be sent.
        tmuxSessionManager?.detach()
        
        // Tear down serial write queue (after detach has been queued)
        // finish() will cause the consumer to drain remaining items including detach.
        // #64: Do NOT cancel writeConsumerTask — cancellation can drop the detach
        // command that was just queued. finish() terminates the AsyncStream, causing
        // the consumer's `for await` to exit naturally after draining all items.
        writeContinuation?.finish()
        writeConsumerTask = nil
        writeContinuation = nil
        writeStream = nil
        
        tmuxSessionManager?.cleanup()
        tmuxSessionManager = nil
        connection?.disconnect()
        connection = nil
        state = .disconnected
        
        // Clear stored credentials on explicit disconnect
        storedAuthMethod = nil
        storedProfile = nil
        storedCredential = nil
    }
    
    // MARK: - App Lifecycle & Auto-Reconnect
    
    /// Check if the connection is alive
    var isConnectionAlive: Bool {
        guard let conn = connection else { return false }
        return conn.state != .disconnected
    }
    
    /// Check if we have stored credentials for reconnect
    var canReconnect: Bool {
        return storedAuthMethod != nil
    }
    
    /// Called when the app is about to go to background.
    /// Captures a snapshot of the current session state so `appDidBecomeActive()`
    /// knows to reconnect. Does NOT send `detach-client` — instead, we let iOS
    /// suspend the process and the SSH connection dies from neglect. The tmux
    /// session persists server-side and is reattached on foreground.
    ///
    /// Uses `beginBackgroundTask` to buy ~30s of background execution time,
    /// giving any in-flight SSH writes time to flush before iOS suspends.
    func appWillResignActive() {
        guard controlModeState.isActive else { return }
        
        // Capture a snapshot of the session state before backgrounding.
        // This tells appDidBecomeActive() that we had an active session
        // and should reconnect. Also used by connectionDidClose to suppress
        // the disconnect-navigation flow (SSH dying during background is expected).
        backgroundState = BackgroundSessionState(
            controlModeWasActive: true,
            tmuxSessionName: tmuxSessionName
        )
        
        // Start a background task to protect any in-flight SSH writes.
        // Without this, iOS suspends the app in ~5s and the TCP socket
        // dies mid-write. We don't send detach-client anymore, but any
        // pending Ghostty writes should still flush cleanly.
        beginBackgroundTaskIfNeeded()
        
        logger.info("App resigning active — captured background state (no detach sent)")
        
        // Safety timer to end background task after 5s. We're not waiting
        // for anything specific (no detach-client response), but the grace
        // period lets any in-flight data finish writing.
        // Cancel any previous timer to prevent stale timers from ending
        // a new background task prematurely on rapid bg/fg cycling.
        backgroundSafetyTimerTask?.cancel()
        backgroundSafetyTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.endBackgroundTaskIfNeeded()
        }
    }
    
    /// Called when the app becomes active again.
    /// If we had an active tmux session when backgrounded, sends C1 ST (0x9C)
    /// to cleanly exit the stale DCS passthrough state, then reconnects via
    /// a fresh SSH connection to reattach to the tmux session.
    func appDidBecomeActive() {
        logger.info("App became active, checking connection health... backgroundState=\(self.backgroundState != nil)")
        
        // Cancel the safety timer and end any lingering background task
        backgroundSafetyTimerTask?.cancel()
        backgroundSafetyTimerTask = nil
        endBackgroundTaskIfNeeded()
        
        // If already reconnecting, don't start another attempt
        guard !isReconnecting else {
            logger.info("Already reconnecting, skipping")
            return
        }
        
        // Background reattach path: we had an active tmux session when backgrounded.
        // The SSH connection is dead (iOS suspended us), but the tmux session is
        // alive server-side. We need a fresh SSH connection to reattach.
        //
        // IMPORTANT: We do NOT clear backgroundState here. It must remain non-nil
        // so that (a) connectionDidClose suppresses the delegate notification when
        // the NIO event loop discovers the dead TCP socket, and (b) the TMUX_EXIT
        // handler (triggered by C1 ST below) calls prepareForReattach() instead of
        // the nuclear controlModeExited(). backgroundState is cleared inside
        // attemptReconnect() after isReconnecting is set, providing seamless
        // suppression handoff.
        if let bgState = backgroundState {
            // Send C1 ST (0x9C) to the Ghostty surface to exit the stale DCS
            // passthrough state. This triggers:
            //   parser: dcs_passthrough → ground (via 0x9C "anywhere" transition)
            //   dcs_unhook → .tmux = .exit → viewer teardown
            //   GHOSTTY_ACTION_TMUX_EXIT fires → TMUX_EXIT handler
            //   isDetachingForBackground is still true → prepareForReattach()
            // After this, the parser is in ground state and ready for fresh DCS 1000p.
            if bgState.controlModeWasActive, let surface = ghosttySurface {
                logger.info("Sending C1 ST (0x9C) to exit stale DCS passthrough")
                surface.feedData(Data([0x9C]))
            }
            
            if canReconnect {
                logger.info("Background session restored, initiating reattach via new SSH connection")
                Task {
                    await attemptReconnect()
                }
            } else {
                backgroundState = nil
                logger.warning("Background session restored but no stored credentials for reattach")
                tmuxSessionManager?.controlModeExited(reason: "Cannot reattach — no stored credentials")
            }
            return
        }
        
        // If connection is alive, nothing to do
        if isConnectionAlive, controlModeState.isActive {
            logger.info("Connection alive, control mode active")
            return
        }
        
        // Connection is dead — attempt to reconnect if we have credentials
        if !isConnectionAlive && canReconnect {
            logger.info("Connection dead, attempting auto-reconnect...")
            Task {
                await attemptReconnect()
            }
        } else if !isConnectionAlive {
            logger.warning("Connection dead but no stored credentials for reconnect")
            // Notify session manager of connection loss
            tmuxSessionManager?.controlModeExited(reason: "Connection lost")
        }
    }
    
    /// Attempt to reconnect to the SSH server.
    /// Called from appDidBecomeActive() for auto-reconnect, and can be called
    /// externally (e.g., from a Reconnect button in ContentView).
    func attemptReconnect() async {
        guard !isReconnecting else { return }
        
        isReconnecting = true
        // Now that isReconnecting is true, connectionDidClose will be suppressed
        // by the reconnect guard. Safe to clear backgroundState — its suppression
        // role is handed off to isReconnecting.
        backgroundState = nil
        defer { isReconnecting = false }
        
        // #62: Reset counter before the loop so subsequent calls (e.g., from
        // a manual Reconnect button after all attempts were exhausted) don't
        // immediately fall through the while condition.
        reconnectAttempts = 0
        
        while reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            logger.info("Reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts)")
            
            // Clean up old connection state (but keep tmuxSessionManager for surface reuse).
            // Nil the delegate BEFORE disconnecting so the old connection's death
            // rattle doesn't fire connectionDidClose back to us — the stale-connection
            // guard in connectionDidClose is the primary defense, but nilling the
            // delegate is a belt-and-suspenders measure.
            controlModeState = .inactive
            tmuxPaneActivated = false
            activeTmuxPaneId = nil
            viewerReady = false
            sessionDiscoveryState = .idle
            tmuxAttachTimer?.cancel()
            tmuxAttachTimer = nil
            connection?.delegate = nil
            connection?.disconnect()
            connection = nil
            
            do {
                // Reconnect using stored auth method
                guard let authMethod = storedAuthMethod else {
                    throw SSHSessionError.notConnected
                }
                
                try await reconnectWithAuth(authMethod)
                
                // Success!
                reconnectAttempts = 0
                logger.info("Reconnect successful")
                return
                
            } catch is CancellationError {
                logger.info("Reconnect cancelled")
                return
            } catch {
                logger.error("Reconnect failed: \(error.localizedDescription)")
                
                guard reconnectAttempts < maxReconnectAttempts else {
                    tmuxSessionManager?.controlModeExited(reason: "Reconnect failed: \(error.localizedDescription)")
                    return
                }
                
                // Retry after delay — propagate cancellation properly
                logger.info("Retrying in 2 seconds...")
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    logger.info("Reconnect retry cancelled during sleep")
                    return
                }
            }
        }
        
        logger.error("Max reconnect attempts (\(maxReconnectAttempts)) reached")
        tmuxSessionManager?.controlModeExited(reason: "Reconnect failed after \(maxReconnectAttempts) attempts")
    }
    
    /// Reconnect using stored auth method
    private func reconnectWithAuth(_ authMethod: SSHAuthMethod) async throws {
        let conn = NIOSSHConnection(host: host, port: port, username: username)
        conn.cols = terminalCols
        conn.rows = terminalRows
        conn.connectionTimeoutSeconds = 5  // Faster timeout for reconnect (vs 15s for initial)
        conn.delegate = self
        connection = conn
        
        // Set up fresh serial write queue for the new connection
        // await ensures the old consumer task completes before starting a new one
        await setupWriteStream()
        
        try await conn.connect(authMethod: authMethod)
        
        // Re-setup tmux session manager — but PRESERVE the existing one if it
        // has a primary surface (background reattach case). Creating a new manager
        // would destroy the primary surface, factory closures, and input/resize
        // handlers captured from the view controller.
        //
        // After prepareForReattach(), paneSurfaces is empty (observer surfaces were
        // destroyed) but primarySurface is preserved. We check primarySurface != nil
        // to detect the reattach case. The standard initial-connect flow will
        // recreate observer surfaces fresh via handleTmuxStateChanged → getSurfaceOrCreate.
        if tmuxMode == .controlMode {
            if let existingManager = tmuxSessionManager, existingManager.primarySurface != nil {
                // Reattach case: manager has the primary surface from the previous session.
                // Just re-wire the write function to use the new SSH connection.
                logger.info("Preserving existing TmuxSessionManager (primarySurface alive, \(existingManager.paneSurfaces.count) pane surfaces)")
                existingManager.setupWithDirectWrite { [weak self] command in
                    Task { @MainActor in
                        self?.writeControlCommand(command)
                    }
                }
                // Re-register notification observers (they were left intact during
                // background detach, but the surface they filter on is the same)
                observeTmuxNotifications()
            } else {
                // Fresh connection or no primary surface — create new manager
                setupTmuxSessionManager()
            }
        }
        
        // Re-attach to tmux session
        injectTerminalSetup()
    }
    
    // MARK: - Background Task Management
    
    /// Begin a background task to give in-flight SSH writes time to flush.
    /// Called from `appWillResignActive()` so any pending data makes it through
    /// the SSH channel before iOS suspends the app.
    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else {
            logger.debug("Background task already active (id=\(self.backgroundTaskID.rawValue))")
            return
        }
        
        backgroundTaskID = backgroundTaskProvider.beginBackgroundTask(
            withName: "GeisttyTmuxDetach"
        ) { [weak self] in
            // Expiration handler — iOS is about to force-suspend us.
            // End the task to avoid being killed.
            Task { @MainActor [weak self] in
                self?.logger_backgroundTaskExpired()
                self?.endBackgroundTaskIfNeeded()
            }
        }
        
        if backgroundTaskID == .invalid {
            logger.warning("Failed to begin background task — iOS denied the request")
        } else {
            logger.info("Background task started (id=\(self.backgroundTaskID.rawValue))")
        }
    }
    
    /// End the background task, signaling iOS that we're done with
    /// background work and can be safely suspended.
    /// Safe to call multiple times — guards against `.invalid`.
    func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        
        let taskID = backgroundTaskID
        backgroundTaskID = .invalid
        backgroundTaskProvider.endBackgroundTask(taskID)
        logger.info("Background task ended (id=\(taskID.rawValue))")
    }
    
    /// Separated to avoid capture issues with logger in the expiration closure
    private func logger_backgroundTaskExpired() {
        logger.warning("Background task expiring — iOS forcing suspension")
    }
    
    #if DEBUG
    /// Test-only accessor for background task state
    var backgroundTaskIDForTesting: UIBackgroundTaskIdentifier {
        backgroundTaskID
    }
    
    #endif
    
    // Internal method to handle received data, called from connection delegate
    fileprivate func handleReceivedData(_ data: Data) {
        #if DEBUG
        logger.debug("[recv] \(data.count)B state=\(self.controlModeState) tmux=\(String(describing: self.tmuxMode))")
        #endif
        
        // Session discovery: intercept tmux list-sessions response before control mode starts.
        // This runs as a raw shell command before `exec tmux -CC`, so the output arrives
        // as normal shell data. We accumulate it until we see the ---END--- sentinel.
        if case .querying(var buffer, let endMarker) = sessionDiscoveryState {
            if let str = String(data: data, encoding: .utf8) {
                buffer += str
                
                if TmuxSessionNameResolver.isResponseComplete(buffer, endMarker: endMarker) {
                    // Parse and resolve
                    let responseText = TmuxSessionNameResolver.extractResponse(from: buffer, endMarker: endMarker) ?? buffer
                    let sessions = TmuxSessionNameResolver.parseSessions(from: responseText, endMarker: endMarker)
                    let resolvedName = TmuxSessionNameResolver.resolve(from: sessions)
                    
                    logger.info("Session discovery complete: found \(sessions.count) sessions, resolved to '\(resolvedName)'")
                    
                    // Done with discovery — transition to awaitingControlMode to suppress
                    // the shell echo of `exec tmux -CC` until DCS 1000p arrives. See #68.
                    // The tmuxAttachTimer is still running and covers this phase too.
                    sessionDiscoveryState = .awaitingControlMode
                    
                    // Now send the actual tmux attach command
                    sendTmuxAttachCommand(sessionName: resolvedName)
                    
                    // #57: Forward any trailing data after the end marker.
                    // A single SSH chunk may contain both the discovery response
                    // and subsequent data (e.g., DCS 1000p from tmux -CC).
                    if let endRange = buffer.range(of: endMarker) {
                        let afterMarker = buffer[endRange.upperBound...]
                        let trimmed = afterMarker.drop(while: { $0 == "\n" || $0 == "\r" })
                        if !trimmed.isEmpty, let trailingData = String(trimmed).data(using: .utf8) {
                            self.handleReceivedData(trailingData)
                        }
                    }
                } else {
                    // Still accumulating response
                    sessionDiscoveryState = .querying(buffer: buffer, endMarker: endMarker)
                }
            }
            return
        }
        
        // #68: After session discovery, suppress data until DCS 1000p arrives.
        // This prevents the shell echo of `exec tmux -CC new-session ...` from
        // rendering on the terminal surface before control mode activates.
        if case .awaitingControlMode = sessionDiscoveryState {
            // Check if this data contains the DCS 1000p sequence that signals
            // tmux control mode activation.
            let dcs1000p = Data([0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]) // ESC P 1 0 0 0 p
            if let dcsRange = data.range(of: dcs1000p) {
                // Found DCS 1000p — transition to idle and forward from the DCS sequence onward.
                // Everything before DCS 1000p is shell echo garbage; discard it.
                logger.info("#68: DCS 1000p detected in \(data.count)B chunk, transitioning to idle")
                sessionDiscoveryState = .idle
                tmuxAttachTimer?.cancel()
                tmuxAttachTimer = nil
                
                let dcsAndAfter = data[dcsRange.lowerBound...]
                if !dcsAndAfter.isEmpty {
                    self.handleReceivedData(Data(dcsAndAfter))
                }
            } else {
                // No DCS 1000p yet — suppress this data entirely.
                // It's shell echo from the exec command.
                logger.debug("#68: Suppressing \(data.count)B while awaiting DCS 1000p")
            }
            return
        }
        
        // All data goes to Ghostty, which handles DCS 1000p detection and tmux
        // control mode protocol parsing natively via its internal tmux viewer.
        // No gateway routing or DCS filtering needed on the Swift side.
        if let delegate = delegate {
            logger.info("📥 Forwarding \(data.count)B to delegate")
            delegate.sshSession(self, didReceiveData: data)
        } else {
            // No delegate yet — buffer for flush when delegate is set.
            // This happens in the pre-connected session flow between connect()
            // returning and useExistingSession() setting the delegate.
            logger.info("📥 Buffering \(data.count)B (no delegate yet, \(earlyReceiveBuffer.count) chunks queued)")
            earlyReceiveBuffer.append(data)
        }
    }
    
    // MARK: - Test Helpers
    
    #if DEBUG
    /// Set control mode state for testing. Only available in DEBUG builds.
    func setControlModeStateForTesting(_ state: ControlModeState) {
        controlModeState = state
    }
    
    /// Set active tmux pane ID for testing. Only available in DEBUG builds.
    func setActiveTmuxPaneIdForTesting(_ paneId: Int?) {
        activeTmuxPaneId = paneId
    }
    
    /// Set tmux mode for testing. Only available in DEBUG builds.
    func setTmuxModeForTesting(_ mode: TmuxMode) {
        tmuxMode = mode
    }
    
    /// Set connection health for testing. Only available in DEBUG builds.
    func setConnectionHealthForTesting(_ health: ConnectionHealth) {
        connectionHealth = health
    }
    
    /// Set viewer ready state for testing. Only available in DEBUG builds.
    func setViewerReadyForTesting(_ ready: Bool) {
        viewerReady = ready
    }
    
    /// Set tmux pane activated for testing. Only available in DEBUG builds.
    func setTmuxPaneActivatedForTesting(_ activated: Bool) {
        tmuxPaneActivated = activated
    }
    
    /// Set background state for testing. Only available in DEBUG builds.
    /// Pass `true` to simulate a backgrounded tmux session (sets backgroundState
    /// with controlModeWasActive=true). Pass `false` to clear it.
    func setBackgroundStateForTesting(_ value: Bool) {
        if value {
            backgroundState = BackgroundSessionState(
                controlModeWasActive: true,
                tmuxSessionName: nil
            )
        } else {
            backgroundState = nil
        }
    }
    
    /// Legacy alias for setBackgroundStateForTesting — keeps existing tests working.
    func setIsDetachingForBackgroundForTesting(_ value: Bool) {
        setBackgroundStateForTesting(value)
    }
    
    /// Set up tmux session manager for testing. Only available in DEBUG builds.
    /// This calls the real setupTmuxSessionManager() which creates a TmuxSessionManager
    /// and registers notification observers.
    func setupTmuxForTesting() {
        tmuxMode = .controlMode
        useTmux = true
        setupTmuxSessionManager()
    }
    
    /// Simulate received data for testing. Only available in DEBUG builds.
    /// Calls handleReceivedData() which is normally fileprivate.
    func simulateReceivedDataForTesting(_ data: Data) {
        handleReceivedData(data)
    }
    
    /// Get the pending input queue for testing verification.
    var pendingInputQueueForTesting: [Data] {
        pendingInputQueue
    }
    
    /// Get the early receive buffer for testing verification.
    var earlyReceiveBufferForTesting: [Data] {
        earlyReceiveBuffer
    }
    
    /// Simulate NIOSSHConnection calling connectionDidClose for testing.
    /// Creates a throwaway NIOSSHConnection and invokes the delegate method,
    /// exercising the real `isDetachingForBackground` suppression logic.
    ///
    /// By default, uses a dummy connection (simulating a stale/unknown connection).
    /// Pass `useCurrentConnection: true` to simulate the *current* connection closing
    /// (e.g., when the active connection dies without reconnect in progress).
    func simulateConnectionDidCloseForTesting(error: Error? = nil, useCurrentConnection: Bool = false) {
        if useCurrentConnection, let conn = connection {
            connectionDidClose(conn, error: error)
        } else {
            let dummyConnection = NIOSSHConnection(host: "test", port: 22, username: "test")
            connectionDidClose(dummyConnection, error: error)
        }
    }
    
    /// Set isReconnecting for testing. Only available in DEBUG builds.
    func setIsReconnectingForTesting(_ value: Bool) {
        isReconnecting = value
    }
    
    /// Set a mock connection for testing. Only available in DEBUG builds.
    func setConnectionForTesting(_ conn: NIOSSHConnection?) {
        connection = conn
    }
    
    /// Get the current connection for testing verification. Only available in DEBUG builds.
    var connectionForTesting: NIOSSHConnection? {
        connection
    }
    
    /// Set session discovery state for testing (#68). Only available in DEBUG builds.
    func setSessionDiscoveryStateAwaitingForTesting() {
        sessionDiscoveryState = .awaitingControlMode
    }
    
    /// Set session discovery state to idle for testing. Only available in DEBUG builds.
    func setSessionDiscoveryStateIdleForTesting() {
        sessionDiscoveryState = .idle
    }
    
    /// Check if session discovery state is awaitingControlMode. Only available in DEBUG builds.
    var isAwaitingControlModeForTesting: Bool {
        if case .awaitingControlMode = sessionDiscoveryState { return true }
        return false
    }
    
    /// Check if session discovery state is idle. Only available in DEBUG builds.
    var isSessionDiscoveryIdleForTesting: Bool {
        if case .idle = sessionDiscoveryState { return true }
        return false
    }
    #endif
}

// MARK: - NIOSSHConnectionDelegate

// All delegate methods are called from NIOSSHConnection's closures which already
// run inside Task { @MainActor }. Both NIOSSHConnection and SSHSession are @MainActor.
// No nonisolated + Task wrapper needed — that pattern created unnecessary unstructured
// Tasks which, on the hot data path (didReceiveData), could reorder SSH data chunks
// under high throughput (cmatrix, blightmud via tmux) and corrupt the tmux control
// mode byte stream.
extension SSHSession: NIOSSHConnectionDelegate {
    func connectionDidConnect(_ connection: NIOSSHConnection) {
        self.state = .connected
    }
    
    func connectionDidAuthenticate(_ connection: NIOSSHConnection) {
        self.state = .authenticated
        self.delegate?.sshSessionDidConnect(self)
    }
    
    func connectionDidFailAuthentication(_ connection: NIOSSHConnection, error: Error) {
        self.lastError = error
        self.state = .disconnected
        self.delegate?.sshSession(self, didDisconnectWithError: error)
    }
    
    func connectionDidClose(_ connection: NIOSSHConnection, error: Error?) {
        // Stale connection guard: during reconnect, attemptReconnect() calls
        // oldConnection.disconnect() which fires this callback. If `connection`
        // is not our current self.connection, it's a death rattle from the old
        // connection — ignore it to prevent spurious UI navigation.
        if connection !== self.connection && self.connection != nil {
            logger.info("Ignoring connectionDidClose from stale connection (reconnect in progress)")
            return
        }
        
        self.lastError = error
        self.state = .disconnected
        
        // Suppress disconnect notifications during expected teardown scenarios.
        // Both background detach and reconnect involve intentional connection
        // closure — notifying the delegate would trigger SwiftUI to remove
        // TerminalContainerView, causing full surface teardown and a renderer
        // use-after-free SIGSEGV.
        if shouldSuppressDisconnectNotification {
            let reason = isDetachingForBackground ? "background detach" : "reconnect"
            logger.info("SSH channel closed during \(reason) — suppressing disconnect notification")
            return
        }
        
        self.delegate?.sshSession(self, didDisconnectWithError: error)
    }
    
    func connection(_ connection: NIOSSHConnection, didReceiveData data: Data) {
        self.handleReceivedData(data)
    }
    
    func connection(_ connection: NIOSSHConnection, healthDidChange health: ConnectionHealth) {
        self.connectionHealth = health
        logger.info("🔌 Connection health changed: \(String(describing: health))")
        
        // Notify delegate
        self.delegate?.sshSession(self, healthDidChange: health)
        
        // If connection became healthy again and we have pending input, flush it.
        // Route through Ghostty for proper send-keys wrapping in tmux mode.
        if health.isHealthy && !self.pendingInputQueue.isEmpty {
            logger.info("Connection healthy, flushing \(self.pendingInputQueue.count) queued inputs")
            self.flushPendingInput()
        }
    }
}

