//
//  RawTerminalUIViewController+Search.swift
//  Geistty
//
//  Search/Find overlay management for the terminal view controller.
//

import UIKit
import SwiftUI
import Combine
import GhosttyKit
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Terminal")

// MARK: - Search / Find

extension RawTerminalUIViewController {
    
    func handleFind() {
        guard let surface = surfaceView else { return }
        
        // Send start_search action to Ghostty, which will trigger the START_SEARCH callback
        // This matches the macOS implementation and ensures proper state management
        surface.startSearch()
    }
    
    func handleFindNext() {
        guard let surface = surfaceView else { return }
        
        if surface.searchState != nil {
            // Search active, go to next result
            surface.searchNext()
        } else {
            // No search active, start one first
            handleFind()
        }
    }
    
    func handleFindPrevious() {
        guard let surface = surfaceView else { return }
        
        if surface.searchState != nil {
            // Search active, go to previous result
            surface.searchPrevious()
        } else {
            // No search active, start one first
            handleFind()
        }
    }
    
    func closeSearch() {
        guard let surface = surfaceView else { return }
        
        // Directly set searchState to nil - the didSet will send end_search to Ghostty
        // This matches the macOS implementation
        surface.searchState = nil
        
        // Return focus to terminal
        _ = surface.becomeFirstResponder()
    }
    
    // MARK: - Search Overlay Management
    
    func updateSearchOverlay() {
        guard let surface = surfaceView else {
            removeSearchOverlay()
            return
        }
        
        if let searchState = surface.searchState {
            // Show/update search overlay
            if searchOverlayHostingController == nil {
                // Create and add the overlay
                let overlay = Ghostty.SurfaceSearchOverlay(
                    surfaceView: surface,
                    searchState: searchState,
                    onClose: { [weak self] in
                        self?.closeSearch()
                    }
                )
                
                let hostingController = UIHostingController(rootView: overlay)
                hostingController.view.backgroundColor = .clear
                
                // KEY FIX: Use Auto Layout to size the hosting view to fit its content
                // instead of stretching it full-screen. This is the iOS-native way to
                // have an overlay that doesn't block touches on the rest of the screen.
                hostingController.view.translatesAutoresizingMaskIntoConstraints = false
                
                // Tell the hosting controller to size itself to fit content
                hostingController.sizingOptions = .intrinsicContentSize
                
                addChild(hostingController)
                view.addSubview(hostingController.view)
                
                // Create constraints for all four corners (we'll activate/deactivate as needed)
                let padding: CGFloat = 12
                searchBarTopConstraint = hostingController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: padding)
                searchBarBottomConstraint = hostingController.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -padding)
                searchBarLeadingConstraint = hostingController.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: padding)
                searchBarTrailingConstraint = hostingController.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -padding)
                
                // Activate constraints for current corner
                updateSearchBarConstraints()
                
                // Add pan gesture for dragging
                let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleSearchBarPan(_:)))
                hostingController.view.addGestureRecognizer(panGesture)
                
                hostingController.didMove(toParent: self)
                searchOverlayHostingController = hostingController
            }
        } else {
            removeSearchOverlay()
        }
    }
    
    func updateSearchBarConstraints() {
        // Deactivate all
        searchBarTopConstraint?.isActive = false
        searchBarBottomConstraint?.isActive = false
        searchBarLeadingConstraint?.isActive = false
        searchBarTrailingConstraint?.isActive = false
        
        // Activate based on corner
        switch searchBarCorner {
        case .topLeft:
            searchBarTopConstraint?.isActive = true
            searchBarLeadingConstraint?.isActive = true
        case .topRight:
            searchBarTopConstraint?.isActive = true
            searchBarTrailingConstraint?.isActive = true
        case .bottomLeft:
            searchBarBottomConstraint?.isActive = true
            searchBarLeadingConstraint?.isActive = true
        case .bottomRight:
            searchBarBottomConstraint?.isActive = true
            searchBarTrailingConstraint?.isActive = true
        }
    }
    
    @objc func handleSearchBarPan(_ gesture: UIPanGestureRecognizer) {
        guard let searchView = searchOverlayHostingController?.view else { return }
        
        switch gesture.state {
        case .changed:
            // Move the view with the finger
            let translation = gesture.translation(in: view)
            searchView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            
        case .ended, .cancelled:
            // Get the translation and velocity
            let translation = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)
            
            // Calculate where the view visually ended up (center + translation)
            let visualCenter = CGPoint(
                x: searchView.center.x + translation.x,
                y: searchView.center.y + translation.y
            )
            
            let viewBounds = view.bounds
            let midX = viewBounds.width / 2
            let midY = viewBounds.height / 2
            
            // Flick threshold - if velocity is high enough, use velocity direction
            let flickThreshold: CGFloat = 500
            let isFlick = abs(velocity.x) > flickThreshold || abs(velocity.y) > flickThreshold
            
            let newCorner: SearchBarCorner
            if isFlick {
                // Use velocity direction to determine target corner
                let goingLeft = velocity.x < 0
                let goingUp = velocity.y < 0
                
                if goingLeft {
                    newCorner = goingUp ? .topLeft : .bottomLeft
                } else {
                    newCorner = goingUp ? .topRight : .bottomRight
                }
            } else {
                // Use final position to snap to nearest corner
                if visualCenter.x < midX {
                    newCorner = visualCenter.y < midY ? .topLeft : .bottomLeft
                } else {
                    newCorner = visualCenter.y < midY ? .topRight : .bottomRight
                }
            }
            
            // Reset transform and update corner
            searchBarCorner = newCorner
            UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                searchView.transform = .identity
                self.updateSearchBarConstraints()
                self.view.layoutIfNeeded()
            }
            
        default:
            break
        }
    }
    
    func removeSearchOverlay() {
        if let hostingController = searchOverlayHostingController {
            hostingController.willMove(toParent: nil)
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
            searchOverlayHostingController = nil
        }
    }
    
    func setupSearchStateObserver() {
        // Observe search state changes on the surface view
        guard let surface = surfaceView else { return }
        
        searchStateObserver = surface.$searchState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateSearchOverlay()
            }
        
        // Observe active key table changes for vim-style modal indicator
        keyTableObserver = surface.$activeKeyTable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tableName in
                self?.updateKeyTableIndicator(tableName: tableName)
            }
    }
}
