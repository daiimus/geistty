//
//  RawTerminalUIViewController+StatusBar.swift
//  Geistty
//
//  tmux status bar management for the terminal view controller.
//  Shows the expanded status-left/right text at the bottom of the terminal
//  when tmux >= 3.2 provides format subscription data.
//

import UIKit
import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Terminal")

// MARK: - Status Bar

extension RawTerminalUIViewController {

    /// Observe status-left/right changes to show/hide the tmux status bar
    func setupStatusBarObserver() {
        guard let tmuxManager = viewModel?.tmuxManager else {
            logger.debug("No tmux manager available for status bar observation")
            return
        }

        // Cancel any existing observer
        statusBarObserver?.cancel()

        statusBarObserver = Publishers.CombineLatest(
            tmuxManager.$statusLeft,
            tmuxManager.$statusRight
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] left, right in
            self?.handleStatusBarChange(left: left, right: right)
        }

        logger.info("Status bar observer configured")
    }

    /// Handle status text changes - show/hide the status bar
    private func handleStatusBarChange(left: String, right: String) {
        let hasContent = !left.isEmpty || !right.isEmpty

        if hasContent && !isShowingTmuxStatusBar {
            showTmuxStatusBar()
        } else if !hasContent && isShowingTmuxStatusBar {
            hideTmuxStatusBar()
        }
    }

    /// Show the tmux status bar at the bottom of the terminal view
    func showTmuxStatusBar() {
        guard let tmuxManager = viewModel?.tmuxManager else { return }
        guard statusBarHostingController == nil else { return }

        logger.info("Showing tmux status bar")

        let statusBarView = TmuxStatusBarView(sessionManager: tmuxManager)
        let hostingController = UIHostingController(rootView: statusBarView)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        // Position at the bottom of the safe area to avoid the home indicator
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            hostingController.view.heightAnchor.constraint(equalToConstant: tmuxStatusBarHeight)
        ])

        statusBarHostingController = hostingController
        isShowingTmuxStatusBar = true

        // Adjust terminal view's bottom constraint to make room for the status bar
        updateTerminalBottomConstraint()
    }

    /// Hide the tmux status bar
    func hideTmuxStatusBar() {
        guard let hostingController = statusBarHostingController else { return }

        logger.info("Hiding tmux status bar")

        hostingController.willMove(toParent: nil)
        hostingController.view.removeFromSuperview()
        hostingController.removeFromParent()

        statusBarHostingController = nil
        isShowingTmuxStatusBar = false

        // Restore terminal view's bottom constraint
        updateTerminalBottomConstraint()
    }

    /// Update the terminal view's bottom constraint based on status bar visibility.
    ///
    /// The keyboard handler sets `surfaceBottomConstraint` to `-keyboardHeight`.
    /// When the status bar is visible but the keyboard is hidden, the terminal bottom
    /// needs to account for the status bar height. When the keyboard IS visible, the
    /// keyboard height dominates (the status bar is pushed off-screen by the keyboard).
    func updateTerminalBottomConstraint() {
        // The status bar is pinned to safeAreaLayoutGuide.bottomAnchor, so the
        // terminal must clear both the safe area inset and the status bar height.
        let safeBottom = view.safeAreaInsets.bottom
        let statusBarOffset: CGFloat = isShowingTmuxStatusBar ? -(tmuxStatusBarHeight + safeBottom) : 0

        // Only apply status bar offset if the keyboard is not already pushing
        // the terminal up. Use the tracked keyboard height rather than reading
        // the constraint value, which could be stale during state transitions
        // (e.g. hiding the status bar while the constraint is still at
        // -statusBarHeight would be misidentified as "keyboard is up").
        let keyboardIsUp = currentKeyboardHeight > 0

        if !keyboardIsUp {
            surfaceBottomConstraint?.constant = statusBarOffset
            multiPaneBottomConstraint?.constant = statusBarOffset
        }

        UIView.animate(withDuration: 0.2) {
            self.view.layoutIfNeeded()
        }
    }
}
