//
//  RawTerminalUIViewController+WindowPicker.swift
//  Geistty
//
//  tmux window picker management for the terminal view controller.
//

import UIKit
import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Terminal")

// MARK: - Window Picker

extension RawTerminalUIViewController {
    
    /// Observe windows changes to show/hide the window picker
    func setupWindowsObserver() {
        guard let tmuxManager = viewModel?.tmuxManager else {
            logger.debug("No tmux manager available for windows observation")
            return
        }
        
        // Cancel any existing observer
        windowsObserver?.cancel()
        
        windowsObserver = tmuxManager.$windows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] windows in
                self?.handleWindowsChange(windowCount: windows.count)
            }
        
        logger.info("✅ Windows observer configured")
    }
    
    /// Handle windows count change - show/hide window picker
    func handleWindowsChange(windowCount: Int) {
        let shouldShowPicker = windowCount > 1
        
        if shouldShowPicker && !isShowingWindowPicker {
            showWindowPicker()
        } else if !shouldShowPicker && isShowingWindowPicker {
            hideWindowPicker()
        }
    }
    
    /// Show the window picker at the top of the view
    func showWindowPicker() {
        guard let tmuxManager = viewModel?.tmuxManager else { return }
        guard windowPickerHostingController == nil else { return }
        
        logger.info("📑 Showing window picker")
        
        let pickerView = TmuxWindowPickerView(
            sessionManager: tmuxManager,
            onSessionPickerRequested: { [weak self] in
                self?.showSessionPicker()
            }
        )
        let hostingController = UIHostingController(rootView: pickerView)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)
        
        // Position at the top, below the safe area (status bar).
        // Uses safeAreaLayoutGuide so the constraint auto-updates on rotation
        // or multitasking safe-area changes — no stale constant. (#44 T6)
        let topAnchor = showStatusBar ? view.safeAreaLayoutGuide.topAnchor : view.topAnchor
        
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.heightAnchor.constraint(equalToConstant: windowPickerHeight)
        ])
        
        windowPickerHostingController = hostingController
        isShowingWindowPicker = true
        
        // Adjust terminal view's top constraint to make room for the picker
        updateTerminalTopConstraint()
    }
    
    /// Hide the window picker
    func hideWindowPicker() {
        guard let hostingController = windowPickerHostingController else { return }
        
        logger.info("📑 Hiding window picker")
        
        hostingController.willMove(toParent: nil)
        hostingController.view.removeFromSuperview()
        hostingController.removeFromParent()
        
        windowPickerHostingController = nil
        isShowingWindowPicker = false
        
        // Restore terminal view's top constraint
        updateTerminalTopConstraint()
    }
    
    /// Show the session picker as a modal sheet
    func showSessionPicker() {
        guard let tmuxManager = viewModel?.tmuxManager else { return }
        
        // Guard against double-presentation (keyboard shortcut + menu + button)
        guard presentedViewController == nil else {
            logger.debug("📑 Session picker already presenting, ignoring")
            return
        }
        
        logger.info("📑 Showing session picker")
        
        // Wrap in a container that owns the @State for isPresented and
        // dismisses the hosting controller when the user taps "Done".
        let picker = SessionPickerContainer(
            sessionManager: tmuxManager,
            onDismiss: { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        let hostingController = UIHostingController(rootView: picker)
        hostingController.modalPresentationStyle = .formSheet
        present(hostingController, animated: true)
    }
    
    /// Update the terminal view's top constraint based on window picker visibility
    func updateTerminalTopConstraint() {
        // On iPad, the status bar is always shown (to preserve the system menu bar),
        // so always apply the safe area inset. On iPhone, respect the user's setting.
        let statusBarVisible: Bool
        if UIDevice.current.userInterfaceIdiom == .pad {
            statusBarVisible = true
        } else {
            statusBarVisible = showStatusBar
        }
        let topInset: CGFloat = statusBarVisible ? view.safeAreaInsets.top : 0
        let pickerOffset: CGFloat = isShowingWindowPicker ? windowPickerHeight : 0
        
        surfaceTopConstraint?.constant = topInset + pickerOffset
        multiPaneTopConstraint?.constant = topInset + pickerOffset
        
        UIView.animate(withDuration: 0.2) {
            self.view.layoutIfNeeded()
        }
    }
}
