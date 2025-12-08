//
//  GhosttyTerminalView.swift
//  Bodak
//
//  SwiftUI wrapper for Ghostty.SurfaceView
//

import SwiftUI
import UIKit
import GhosttyKit

/// SwiftUI wrapper for Ghostty terminal surface
struct GhosttyTerminalView: UIViewRepresentable {
    /// The Ghostty app instance
    let app: Ghostty.App
    
    /// Callback when the terminal wants to send data (user input)
    var onWrite: ((Data) -> Void)?
    
    /// Binding to track the surface view for external control
    @Binding var surfaceView: Ghostty.SurfaceView?
    
    /// The size from GeometryReader
    var size: CGSize
    
    func makeUIView(context: Context) -> UIView {
        guard let ghosttyApp = app.app else {
            // Return a placeholder view if app isn't ready
            let placeholder = UIView()
            placeholder.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
            return placeholder
        }
        
        let surfaceView = Ghostty.SurfaceView(ghosttyApp)
        surfaceView.onWrite = onWrite
        
        // Store reference
        DispatchQueue.main.async {
            self.surfaceView = surfaceView
        }
        
        return surfaceView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let surfaceView = uiView as? Ghostty.SurfaceView else { return }
        
        // Update size when geometry changes
        surfaceView.sizeDidChange(size)
        
        // Update write callback
        surfaceView.onWrite = onWrite
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        // Cleanup if needed
    }
}

/// Convenience initializer without binding
extension GhosttyTerminalView {
    init(app: Ghostty.App, size: CGSize, onWrite: ((Data) -> Void)? = nil) {
        self.app = app
        self.size = size
        self.onWrite = onWrite
        self._surfaceView = .constant(nil)
    }
}

// MARK: - Ghostty Terminal Container

/// A complete terminal view with Ghostty surface and optional toolbar
struct GhosttyTerminal: View {
    @EnvironmentObject var ghosttyApp: Ghostty.App
    
    /// Callback when terminal wants to write data
    var onWrite: ((Data) -> Void)?
    
    /// Reference to the surface view
    @State private var surfaceView: Ghostty.SurfaceView?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background color (use config color if available, fallback to dark)
                Color(ghosttyApp.config?.backgroundColor ?? UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0))
                    .ignoresSafeArea()
                
                // Terminal surface
                if ghosttyApp.readiness == .ready {
                    GhosttyTerminalView(
                        app: ghosttyApp,
                        onWrite: onWrite,
                        surfaceView: $surfaceView,
                        size: geometry.size
                    )
                } else if ghosttyApp.readiness == .error {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.red)
                        Text("Failed to initialize terminal")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ProgressView("Initializing...")
                }
            }
        }
    }
    
    /// Feed data to the terminal for display
    func feedData(_ data: Data) {
        surfaceView?.feedData(data)
    }
    
    /// Feed text to the terminal for display
    func feedText(_ text: String) {
        surfaceView?.feedText(text)
    }
}

// MARK: - Preview

#Preview {
    GhosttyTerminal()
        .environmentObject(Ghostty.App())
}
