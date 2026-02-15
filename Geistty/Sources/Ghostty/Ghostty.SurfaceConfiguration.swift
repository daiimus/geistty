//
//  Ghostty.SurfaceConfiguration.swift
//  Geistty
//
//  Backend types and surface configuration — maps Swift types to Ghostty C API structs.
//  Extracted from Ghostty.swift — follows upstream Ghostty macOS naming convention.
//

import Foundation
import UIKit
import GhosttyKit

// MARK: - Ghostty.SurfaceConfiguration

extension Ghostty {
    /// Backend type for terminal I/O
    enum BackendType: Int32 {
        case exec = 0      // Execute subprocess with PTY (default)
        case external = 1  // External data source (SSH, serial)
    }
    
    /// Configuration for creating a new surface
    struct SurfaceConfiguration {
        var fontSize: Float = 14.0
        var workingDirectory: String? = nil
        var command: String? = nil
        var backendType: BackendType = .exec
        
        init() {}
        
        /// Convert to C struct for passing to ghostty_surface_new
        func withCValue<T>(view: UIView, writeCallback: ghostty_write_callback_fn? = nil, resizeCallback: ghostty_resize_callback_fn? = nil, _ body: (inout ghostty_surface_config_s) -> T) -> T {
            var config = ghostty_surface_config_new()
            
            // Set platform info
            config.platform_tag = GHOSTTY_PLATFORM_IOS
            config.platform.ios.uiview = Unmanaged.passUnretained(view).toOpaque()
            
            // Set scale factor
            config.scale_factor = Double(view.contentScaleFactor)
            
            // Set font size
            config.font_size = fontSize
            
            // Set userdata to the view
            config.userdata = Unmanaged.passUnretained(view).toOpaque()
            
            // Set backend type
            config.backend_type = ghostty_backend_type_e(UInt32(backendType.rawValue))
            
            // Set callbacks for external backend
            config.write_callback = writeCallback
            config.resize_callback = resizeCallback
            
            // Set command if provided (only relevant for exec backend)
            if let cmd = command {
                return cmd.withCString { cstr in
                    config.command = cstr
                    return body(&config)
                }
            }
            
            return body(&config)
        }
    }
}
