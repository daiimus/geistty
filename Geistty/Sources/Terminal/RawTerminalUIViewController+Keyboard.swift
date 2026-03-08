//
//  RawTerminalUIViewController+Keyboard.swift
//  Geistty
//
//  Keyboard show/hide handling for the terminal view controller.
//

import UIKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Terminal")

// MARK: - Keyboard Handling

extension RawTerminalUIViewController {
    
    func setupKeyboardObservers() {
        keyboardWillShowObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardWillShow(notification)
        }
        
        keyboardWillHideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardWillHide(notification)
        }
    }
    
    func handleKeyboardWillShow(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int else {
            return
        }
        
        let curve = UIView.AnimationCurve(rawValue: curveValue) ?? .easeInOut
        
        // Calculate how much the keyboard actually overlaps our view.
        // Using .height of the converted rect is incorrect — it gives the keyboard
        // frame's own height regardless of position. We need the overlap between
        // the keyboard and the view's bottom edge. (#44 Bug 2)
        let keyboardFrameInView = view.convert(keyboardFrame, from: nil)
        let keyboardHeight = max(0, view.bounds.maxY - keyboardFrameInView.minY)
        
        // Ignore spurious keyboard notifications with tiny heights (e.g. just the
        // inputAccessoryView at 44pt). On iPad with a hardware keyboard, iOS may
        // post keyboardWillShow for the accessory alone — this shouldn't shift the
        // terminal layout. (#44 Bug 2)
        let minimumKeyboardHeight: CGFloat = 100
        guard keyboardHeight >= minimumKeyboardHeight else {
            logger.debug("⌨️ Ignoring small keyboard height: \(keyboardHeight) (< \(minimumKeyboardHeight))")
            return
        }
        
        // Calculate the new size BEFORE animating
        // Account for top offset (safe area + window picker) so the pre-render
        // hint matches the surface's actual frame after layout. (#44 T9)
        let topOffset = surfaceTopConstraint?.constant ?? 0
        let newHeight = view.bounds.height - keyboardHeight - topOffset
        let newSize = CGSize(width: view.bounds.width, height: max(0, newHeight))
        
        // Notify Ghostty of size change BEFORE animation to pre-render
        // This prevents the white flash during resize
        if let surface = self.surfaceView, !isMultiPaneMode {
            surface.sizeDidChange(newSize)
        }
        
        // Disable implicit CALayer animations during resize (C6 fix:
        // commit immediately after UIView.animate call, not in completion block —
        // UIView.animate is non-blocking so the transaction would be left open
        // for the entire animation duration otherwise)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Animate the bottom constraint
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curve.rawValue << 16)),
            animations: {
                self.surfaceBottomConstraint?.constant = -keyboardHeight
                self.multiPaneBottomConstraint?.constant = -keyboardHeight
                self.view.layoutIfNeeded()
            }
        )
        
        CATransaction.commit()
        
        currentKeyboardHeight = keyboardHeight
        logger.debug("Keyboard will show, height: \(keyboardHeight)")
    }
    
    func handleKeyboardWillHide(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int else {
            return
        }
        
        // If the bottom constraint is already at the resting position (e.g. we
        // ignored a small keyboardWillShow), skip the hide animation to avoid
        // unnecessary layout. The resting position accounts for the status bar
        // height and safe area when the tmux status bar is visible. (#44 Bug 2)
        let restingOffset: CGFloat
        if isShowingTmuxStatusBar {
            restingOffset = -(tmuxStatusBarHeight + view.safeAreaInsets.bottom)
        } else {
            restingOffset = 0
        }
        guard surfaceBottomConstraint?.constant != restingOffset || multiPaneBottomConstraint?.constant != restingOffset else {
            logger.debug("Keyboard will hide (no-op, constraints already at resting position)")
            return
        }
        
        let curve = UIView.AnimationCurve(rawValue: curveValue) ?? .easeInOut
        
        // Calculate the new size BEFORE animating (full height minus top offset).
        // Account for top offset (safe area + window picker) and bottom offset
        // (status bar + safe area) so the pre-render hint matches the surface's
        // actual frame after layout. (#44 T9)
        let topOffset = surfaceTopConstraint?.constant ?? 0
        let bottomOffset: CGFloat = isShowingTmuxStatusBar ? (tmuxStatusBarHeight + view.safeAreaInsets.bottom) : 0
        let newSize = CGSize(width: view.bounds.width, height: max(0, view.bounds.height - topOffset - bottomOffset))
        
        // Notify Ghostty of size change BEFORE animation to pre-render
        if let surface = self.surfaceView, !isMultiPaneMode {
            surface.sizeDidChange(newSize)
        }
        
        // Disable implicit CALayer animations during resize (C6 fix)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Animate the bottom constraint back to 0
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curve.rawValue << 16)),
            animations: {
                // When the status bar is visible, restore to its offset
                // (status bar height + safe area) instead of 0 so the terminal
                // doesn't overlap it. The status bar is pinned to
                // safeAreaLayoutGuide.bottomAnchor.
                let bottomOffset: CGFloat
                if self.isShowingTmuxStatusBar {
                    bottomOffset = -(self.tmuxStatusBarHeight + self.view.safeAreaInsets.bottom)
                } else {
                    bottomOffset = 0
                }
                self.surfaceBottomConstraint?.constant = bottomOffset
                self.multiPaneBottomConstraint?.constant = bottomOffset
                self.view.layoutIfNeeded()
            }
        )
        
        CATransaction.commit()
        
        currentKeyboardHeight = 0
        logger.debug("Keyboard will hide")
    }
}
