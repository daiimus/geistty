//
//  SurfaceManager.swift
//  Geistty
//
//  Centralized manager for Ghostty terminal surfaces.
//
//  Architecture:
//  - SurfaceManager owns all Ghostty.SurfaceView instances
//  - Surfaces have unique IDs independent of tmux pane IDs
//  - tmux layer maps paneId → surfaceId (not direct surface ownership)
//  - Surfaces can survive tmux session changes (reconnect without recreation)
//
//  Benefits:
//  - Clean separation: terminal rendering vs tmux protocol handling
//  - Surfaces persist across reconnects
//  - Easier testing (mock SurfaceManager)
//  - Future: surface pooling, reuse
//

import Foundation
import UIKit
import Combine
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "SurfaceManager")

// MARK: - Surface Identifier

/// Unique identifier for a managed surface
public struct SurfaceId: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
    
    /// Create a new unique surface ID
    public static func generate() -> SurfaceId {
        SurfaceId(UUID().uuidString)
    }
    
    public var description: String { rawValue }
}

// MARK: - Surface Configuration

/// Configuration for creating a new surface
public struct SurfaceConfiguration {
    /// Unique identifier (if nil, one will be generated)
    public var id: SurfaceId?
    
    /// Label for debugging/logging
    public var label: String?
    
    /// Initial background color (theme-aware)
    public var backgroundColor: UIColor?
    
    public init(
        id: SurfaceId? = nil,
        label: String? = nil,
        backgroundColor: UIColor? = nil
    ) {
        self.id = id
        self.label = label
        self.backgroundColor = backgroundColor
    }
}

// MARK: - Surface Events

/// Events emitted by SurfaceManager
public enum SurfaceEvent {
    /// Surface was created
    case created(id: SurfaceId)
    
    /// Surface was destroyed
    case destroyed(id: SurfaceId)
    
    /// Surface cell size changed
    case cellSizeChanged(id: SurfaceId, size: CGSize)
    
    /// Surface requested resize
    case resizeRequested(id: SurfaceId, cols: Int, rows: Int)
    
    /// Surface received write (keyboard input)
    case writeReceived(id: SurfaceId, data: Data)
}

// MARK: - Managed Surface

/// A surface managed by SurfaceManager
/// Wraps Ghostty.SurfaceView with additional metadata
public class ManagedSurface {
    /// Unique identifier
    public let id: SurfaceId
    
    /// The underlying Ghostty surface
    public let surface: Ghostty.SurfaceView
    
    /// Optional label for debugging
    public var label: String?
    
    /// Creation timestamp
    public let createdAt: Date
    
    /// Current cell size (cached)
    public private(set) var cellSize: CGSize = .zero
    
    init(id: SurfaceId, surface: Ghostty.SurfaceView, label: String? = nil) {
        self.id = id
        self.surface = surface
        self.label = label
        self.createdAt = Date()
    }
    
    func updateCellSize(_ size: CGSize) {
        self.cellSize = size
    }
}

// MARK: - Surface Manager

/// Centralized manager for Ghostty terminal surfaces.
///
/// Usage:
/// ```swift
/// let manager = SurfaceManager()
/// manager.configure(app: ghosttyApp, eventHandler: { event in ... })
/// 
/// // Create surfaces
/// let surfaceId = manager.createSurface(config: .init(label: "pane-0"))
/// 
/// // Map tmux pane to surface
/// paneToSurface["%0"] = surfaceId
/// 
/// // Feed data to surface
/// manager.feedData(data, to: surfaceId)
/// 
/// // Get surface for display
/// if let managed = manager.getSurface(id: surfaceId) {
///     displayView.addSubview(managed.surface)
/// }
/// ```
@MainActor
public class SurfaceManager: ObservableObject {
    
    // MARK: - Properties
    
    /// All managed surfaces (id -> ManagedSurface)
    private var surfaces: [SurfaceId: ManagedSurface] = [:]
    
    /// The Ghostty app instance (required for creating surfaces)
    private var ghosttyApp: Ghostty.App?
    
    /// Event handler for surface events
    private var eventHandler: ((SurfaceEvent) -> Void)?
    
    /// Published count of surfaces (for UI observation)
    @Published public private(set) var surfaceCount: Int = 0
    
    /// Published primary surface ID (first created, or explicitly set)
    @Published public private(set) var primarySurfaceId: SurfaceId?
    
    /// Primary surface cell size (for terminal dimension calculations)
    @Published public private(set) var primaryCellSize: CGSize = .zero
    
    /// Shortcut delegate to assign to new surfaces
    public var shortcutDelegate: Ghostty.SurfaceView.ShortcutDelegate?
    
    /// Default background color for new surfaces
    public var defaultBackgroundColor: UIColor?
    
    // MARK: - Initialization
    
    public init() {
        logger.info("SurfaceManager initialized")
    }
    
    // MARK: - Configuration
    
    /// Configure the manager with a Ghostty app instance
    /// - Parameters:
    ///   - app: The Ghostty app for creating surfaces
    ///   - eventHandler: Callback for surface events
    public func configure(
        app: Ghostty.App,
        eventHandler: @escaping (SurfaceEvent) -> Void
    ) {
        self.ghosttyApp = app
        self.eventHandler = eventHandler
        logger.info("SurfaceManager configured with Ghostty app")
    }
    
    // MARK: - Surface Creation
    
    /// Create a new managed surface
    /// - Parameter config: Surface configuration
    /// - Returns: The surface ID, or nil if creation failed
    @discardableResult
    public func createSurface(config: SurfaceConfiguration = .init()) -> SurfaceId? {
        guard let app = ghosttyApp?.app else {
            logger.error("Cannot create surface - Ghostty app not configured")
            return nil
        }
        
        // Generate or use provided ID
        let id = config.id ?? .generate()
        
        // Check for duplicate ID
        if surfaces[id] != nil {
            logger.warning("Surface with ID \(id) already exists")
            return id
        }
        
        // Create Ghostty surface with external backend
        var ghosttyConfig = Ghostty.SurfaceConfiguration()
        ghosttyConfig.backendType = .external
        
        let surface = Ghostty.SurfaceView(app, baseConfig: ghosttyConfig)
        
        // Apply configuration
        if let bgColor = config.backgroundColor ?? defaultBackgroundColor {
            surface.backgroundColor = bgColor
        }
        
        if let delegate = shortcutDelegate {
            surface.shortcutDelegate = delegate
        }
        
        // Create managed wrapper
        let managed = ManagedSurface(id: id, surface: surface, label: config.label)
        
        // Wire up callbacks
        surface.onCellSizeChanged = { [weak self, id] size in
            self?.handleCellSizeChanged(id: id, size: size)
        }
        
        surface.onResize = { [weak self, id] cols, rows in
            self?.handleResize(id: id, cols: cols, rows: rows)
        }
        
        surface.onWrite = { [weak self, id] data in
            self?.handleWrite(id: id, data: data)
        }
        
        // Store and update count
        surfaces[id] = managed
        surfaceCount = surfaces.count
        
        // Set as primary if first surface
        if primarySurfaceId == nil {
            primarySurfaceId = id
        }
        
        logger.info("Created surface \(id) (label: \(config.label ?? "none"))")
        eventHandler?(.created(id: id))
        
        return id
    }
    
    // MARK: - Surface Access
    
    /// Get a managed surface by ID
    /// - Parameter id: The surface ID
    /// - Returns: The managed surface, or nil if not found
    public func getSurface(id: SurfaceId) -> ManagedSurface? {
        surfaces[id]
    }
    
    /// Get the underlying Ghostty surface by ID
    /// - Parameter id: The surface ID
    /// - Returns: The Ghostty surface view, or nil if not found
    public func getGhosttySurface(id: SurfaceId) -> Ghostty.SurfaceView? {
        surfaces[id]?.surface
    }
    
    /// Get the primary surface
    public var primarySurface: ManagedSurface? {
        guard let id = primarySurfaceId else { return nil }
        return surfaces[id]
    }
    
    /// Get all surface IDs
    public var allSurfaceIds: [SurfaceId] {
        Array(surfaces.keys)
    }
    
    /// Check if a surface exists
    public func surfaceExists(id: SurfaceId) -> Bool {
        surfaces[id] != nil
    }
    
    // MARK: - Surface Operations
    
    /// Feed data to a surface (display terminal output)
    /// - Parameters:
    ///   - data: The data to feed
    ///   - id: The surface ID
    public func feedData(_ data: Data, to id: SurfaceId) {
        guard let managed = surfaces[id] else {
            logger.warning("Cannot feed data - surface \(id) not found")
            return
        }
        managed.surface.feedData(data)
    }
    
    /// Set the primary surface
    /// - Parameter id: The surface ID to set as primary
    public func setPrimarySurface(id: SurfaceId) {
        guard surfaces[id] != nil else {
            logger.warning("Cannot set primary - surface \(id) not found")
            return
        }
        
        let previousId = primarySurfaceId
        primarySurfaceId = id
        
        // Update primary cell size from new primary
        if let managed = surfaces[id] {
            primaryCellSize = managed.cellSize
        }
        
        logger.info("Primary surface changed: \(previousId?.rawValue ?? "none") -> \(id)")
    }
    
    /// Update a surface's label
    /// - Parameters:
    ///   - id: The surface ID
    ///   - label: The new label
    public func setLabel(_ label: String?, for id: SurfaceId) {
        surfaces[id]?.label = label
    }
    
    // MARK: - Surface Destruction
    
    /// Destroy a surface
    /// - Parameter id: The surface ID to destroy
    /// - Returns: True if the surface was destroyed
    @discardableResult
    public func destroySurface(id: SurfaceId) -> Bool {
        guard let managed = surfaces.removeValue(forKey: id) else {
            logger.warning("Cannot destroy - surface \(id) not found")
            return false
        }
        
        // Clean up callbacks
        managed.surface.onCellSizeChanged = nil
        managed.surface.onResize = nil
        managed.surface.onWrite = nil
        
        // Close the Ghostty surface
        managed.surface.close()
        
        // Update count
        surfaceCount = surfaces.count
        
        // Update primary if needed
        if primarySurfaceId == id {
            primarySurfaceId = surfaces.keys.first
            if let newPrimaryId = primarySurfaceId, let newPrimary = surfaces[newPrimaryId] {
                primaryCellSize = newPrimary.cellSize
            } else {
                primaryCellSize = .zero
            }
        }
        
        logger.info("Destroyed surface \(id)")
        eventHandler?(.destroyed(id: id))
        
        return true
    }
    
    /// Destroy all surfaces
    public func destroyAllSurfaces() {
        let ids = Array(surfaces.keys)
        for id in ids {
            destroySurface(id: id)
        }
        logger.info("Destroyed all \(ids.count) surfaces")
    }
    
    // MARK: - Event Handlers (Private)
    
    private func handleCellSizeChanged(id: SurfaceId, size: CGSize) {
        guard let managed = surfaces[id] else { return }
        
        managed.updateCellSize(size)
        
        // Update primary cell size if this is the primary surface
        if id == primarySurfaceId {
            primaryCellSize = size
        }
        
        logger.debug("Surface \(id) cell size: \(Int(size.width))x\(Int(size.height))")
        eventHandler?(.cellSizeChanged(id: id, size: size))
    }
    
    private func handleResize(id: SurfaceId, cols: Int, rows: Int) {
        eventHandler?(.resizeRequested(id: id, cols: cols, rows: rows))
    }
    
    private func handleWrite(id: SurfaceId, data: Data) {
        eventHandler?(.writeReceived(id: id, data: data))
    }
    
    // MARK: - Debug
    
    /// Get debug description of all surfaces
    public var debugDescription: String {
        var lines = ["SurfaceManager: \(surfaceCount) surfaces"]
        for (id, managed) in surfaces {
            let isPrimary = id == primarySurfaceId ? " [PRIMARY]" : ""
            let label = managed.label.map { " (\($0))" } ?? ""
            let cell = "\(Int(managed.cellSize.width))x\(Int(managed.cellSize.height))"
            lines.append("  - \(id.rawValue.prefix(8))...\(label)\(isPrimary) cell=\(cell)")
        }
        return lines.joined(separator: "\n")
    }
}
