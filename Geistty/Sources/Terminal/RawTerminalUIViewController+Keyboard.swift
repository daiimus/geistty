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
        
        // Convert keyboard frame to view coordinates
        let keyboardHeight = view.convert(keyboardFrame, from: nil).height
        
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
        
        logger.debug("⌨️ Keyboard will show, height: \(keyboardHeight)")
    }
    
    func handleKeyboardWillHide(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int else {
            return
        }
        
        let curve = UIView.AnimationCurve(rawValue: curveValue) ?? .easeInOut
        
        // Calculate the new size BEFORE animating (full height minus top offset).
        // Account for top offset (safe area + window picker) so the pre-render
        // hint matches the surface's actual frame after layout. (#44 T9)
        let topOffset = surfaceTopConstraint?.constant ?? 0
        let newSize = CGSize(width: view.bounds.width, height: max(0, view.bounds.height - topOffset))
        
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
                self.surfaceBottomConstraint?.constant = 0
                self.multiPaneBottomConstraint?.constant = 0
                self.view.layoutIfNeeded()
            }
        )
        
        CATransaction.commit()
        
        logger.debug("⌨️ Keyboard will hide")
    }
}
