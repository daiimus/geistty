//
//  ShakeDetector.swift
//  Geistty
//
//  Shake gesture detection for SwiftUI views.
//  Used for "shake to clear" terminal functionality.
//

import SwiftUI
import UIKit

/// UIViewController subclass that detects shake gestures
class ShakeDetectingViewController: UIViewController {
    var onShake: (() -> Void)?
    
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            onShake?()
        }
    }
    
    override var canBecomeFirstResponder: Bool { true }
}

/// SwiftUI wrapper for shake detection
struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void
    
    func makeUIViewController(context: Context) -> ShakeDetectingViewController {
        let vc = ShakeDetectingViewController()
        vc.onShake = onShake
        return vc
    }
    
    func updateUIViewController(_ uiViewController: ShakeDetectingViewController, context: Context) {
        uiViewController.onShake = onShake
    }
}

/// View modifier for adding shake detection
extension View {
    func onShake(perform action: @escaping () -> Void) -> some View {
        self.background(ShakeDetector(onShake: action))
    }
}
