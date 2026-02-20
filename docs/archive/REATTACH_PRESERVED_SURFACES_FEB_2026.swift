// ARCHIVED: Session 127 (February 2026)
//
// Dead code removed from TmuxSessionManager.swift as part of the
// "destroy and recreate" architectural pivot for background reconnection.
//
// The needsReattach / reattachPreservedSurfaces() approach tried to preserve
// observer surfaces across background detach → foreground reconnect and rebind
// their renderer_state.terminal pointers to the new viewer's pane terminals.
// This was inherently fragile and never worked correctly — surfaces always
// showed stale main terminal content (the raw "exec tmux -CC" text).
//
// The replacement approach (Session 126-127) destroys observer surfaces in
// prepareForReattach() and lets the standard initial-connection flow recreate
// them fresh via handleTmuxStateChanged() → getSurfaceOrCreate().
//
// Files affected:
// - TmuxSessionManager.swift (property, method, check in handleTmuxStateChanged)
// - SSHSession.swift (condition changed from paneSurfaces.isEmpty to primarySurface != nil)
// - TmuxSessionManagerTests.swift (10 tests rewritten to test new behavior)

// =============================================================================
// 1. needsReattach property (was at line ~145)
// =============================================================================

    /// Whether preserved surfaces need to be re-attached to the new tmux viewer
    /// after a background detach → foreground reconnect cycle.
    ///
    /// During background detach, `resetAllObservers` (Zig side) resets all observer
    /// surface renderer terminal pointers back to the main terminal, then the viewer
    /// is destroyed. `prepareForReattach()` preserves `paneSurfaces` so the UI stays
    /// intact. When the app foregrounds and reconnects, a NEW tmux viewer is created
    /// with fresh pane terminals. The existing observer surfaces must be re-bound to
    /// the new viewer's pane terminals via `detachTmuxPane()` + `attachToTmuxPane()`.
    ///
    /// Set to `true` by `prepareForReattach()`, consumed by `handleTmuxStateChanged()`
    /// which calls `reattachPreservedSurfaces()` then clears the flag.
    // private(set) var needsReattach: Bool = false

// =============================================================================
// 2. needsReattachForTesting accessor (was at line ~109, inside #if DEBUG)
// =============================================================================

    // /// Test-only: read the needsReattach flag for verifying background detach/reattach lifecycle
    // var needsReattachForTesting: Bool { needsReattach }

// =============================================================================
// 3. needsReattach check in handleTmuxStateChanged() (was at line ~521)
// =============================================================================

        // Re-attach preserved surfaces to the new viewer's pane terminals.
        // After background detach → reconnect, paneSurfaces still has the old
        // surfaces but observer renderers point at the main terminal (from
        // resetAllObservers in the Zig exit handler). The surface creation loop
        // above skips them (paneSurfaces[paneId] != nil). We need to re-bind
        // them to the new viewer's pane terminals so they display pane content
        // instead of the raw shell echo of "exec tmux -CC ...".
        // if needsReattach && !allActivePaneIds.isEmpty {
        //     reattachPreservedSurfaces(paneIds: allActivePaneIds)
        //     needsReattach = false
        // }

// =============================================================================
// 4. reattachPreservedSurfaces() method (was at line ~1061)
// =============================================================================

    /// Re-attach ALL preserved surfaces to the new tmux viewer's pane terminals.
    ///
    /// After a background detach → foreground reconnect cycle:
    /// 1. `resetAllObservers` (Zig) reset observer renderer terminal pointers to the
    ///    main terminal, then the viewer was destroyed.
    /// 2. `prepareForReattach()` preserved `paneSurfaces` so the UI stays intact.
    /// 3. The app reconnected, `exec tmux -CC` created a NEW viewer with fresh pane
    ///    terminals.
    /// 4. `handleTmuxStateChanged()` fired, but the surface creation loop skipped
    ///    existing surfaces (paneSurfaces[paneId] != nil).
    ///
    /// This method handles two types of surfaces:
    ///
    /// **Primary surface**: Re-bound via `setActiveTmuxPane()`, which swaps
    /// `renderer_state.terminal` from the main terminal (showing raw "exec tmux -CC"
    /// echo) to the pane terminal. Also sets `active_pane_id` and registers as observer.
    /// This is the same call `activateFirstTmuxPane()` would make at TMUX_READY time,
    /// but doing it here at TMUX_STATE_CHANGED time eliminates the visual flash of the
    /// raw command text. `activateFirstTmuxPane()` will still run (idempotently).
    ///
    /// **Observer surfaces**: Re-bound by:
    /// - Calling `detachTmuxPane()` to clean up the stale `tmux_pane_binding`
    ///   (which still points at the old, destroyed viewer/pane). This is safe because
    ///   `resetAllObservers` already restored renderer terminal pointers, and the
    ///   old viewer is null so unregister is a no-op.
    /// - Calling `attachToTmuxPane(source:paneId:)` to register with the new viewer's
    ///   pane terminal. The primary surface's stream handler has the NEW viewer by
    ///   this point.
    // private func reattachPreservedSurfaces(paneIds: Set<String>) {
    //     guard let source = primarySurface else {
    //         logger.warning("reattachPreservedSurfaces: no primarySurface, cannot re-attach")
    //         return
    //     }
    //     
    //     var reattachedCount = 0
    //     var primaryRebound = false
    //     
    //     for paneId in TmuxId.sortedNumerically(paneIds) {
    //         guard let surface = paneSurfaces[paneId] else { continue }
    //         
    //         guard let numericId = Int(paneId.dropFirst()) else {
    //             logger.warning("  Cannot parse numeric pane ID from '\(paneId)', skipping")
    //             continue
    //         }
    //         
    //         if surface === source {
    //             let success = source.setActiveTmuxPane(numericId)
    //             if success {
    //                 primaryRebound = true
    //                 logger.info("  Re-bound primary surface to pane \(paneId) via setActiveTmuxPane")
    //             } else {
    //                 logger.warning("  Failed to re-bind primary surface to pane \(paneId)")
    //             }
    //         } else {
    //             surface.detachTmuxPane()
    //             let attached = surface.attachToTmuxPane(source: source, paneId: numericId)
    //             if attached {
    //                 reattachedCount += 1
    //                 logger.info("  Re-attached observer surface for pane \(paneId) to new viewer")
    //             } else {
    //                 logger.warning("  Failed to re-attach observer surface for pane \(paneId)")
    //             }
    //         }
    //     }
    //     
    //     logger.info("reattachPreservedSurfaces complete: primary=\(primaryRebound), \(reattachedCount)/\(paneIds.count - 1) observers re-attached")
    // }

// =============================================================================
// 5. needsReattach = false in controlModeExited() (was at line ~293)
// =============================================================================

        // // Clear reattach flag — this is a full teardown, not a background detach
        // needsReattach = false

// =============================================================================
// 6. needsReattach = false in cleanup() (was at line ~1520)
// =============================================================================

        // // Clear reattach flag — this is a full teardown, not a background detach
        // needsReattach = false
