//
//  BiometricGatekeeper.swift
//  Geistty
//
//  Session-scoped biometric authentication gatekeeper.
//
//  Design decisions:
//  - Opt-in: biometric is NOT enabled by default. Users toggle it per-key.
//  - Session-scoped: auth is valid until the app is backgrounded/suspended.
//    Microsoft-style UX — prompt once when app comes to foreground, not per-connection.
//  - App-level: uses LAContext directly, NOT Keychain access control.
//    This avoids needing to re-key when toggling biometric on/off.
//  - Disable requires auth: toggling biometric OFF requires successful biometric
//    authentication first, preventing silent downgrade on a briefly unlocked device.
//  - Works with any key type: not just SE keys. Users can require biometric for
//    Ed25519, RSA, etc.
//

import Foundation
import UIKit
import LocalAuthentication
import os.log

private let logger = Logger(subsystem: "com.geistty", category: "Biometric")

/// Manages session-scoped biometric authentication for SSH key access.
///
/// Usage flow:
/// 1. Before using a key with `requiresBiometric == true`, call `ensureAuthenticated()`.
/// 2. If the session is already authenticated, this returns immediately.
/// 3. If not, it prompts for Face ID / Touch ID.
/// 4. Authentication is invalidated when the app enters the background.
@MainActor
class BiometricGatekeeper: ObservableObject {
    
    static let shared = BiometricGatekeeper()
    
    /// Whether the user has successfully authenticated in this session.
    @Published private(set) var isAuthenticated = false
    
    /// Whether biometric hardware is available on this device.
    var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
    
    /// Human-readable name for the available biometric type (e.g., "Face ID", "Touch ID").
    var biometricTypeName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Biometrics"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        @unknown default: return "Biometrics"
        }
    }
    
    private var backgroundObserver: NSObjectProtocol?
    
    private init() {
        // Invalidate session when app enters background
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidateSession()
            }
        }
    }
    
    deinit {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    /// Ensure the user is biometrically authenticated for this session.
    ///
    /// If already authenticated (session still valid), returns immediately.
    /// Otherwise, prompts for biometric authentication.
    ///
    /// - Throws: `SSHKeyError.biometricAuthRequired` if authentication fails or is cancelled.
    func ensureAuthenticated() async throws {
        if isAuthenticated {
            logger.debug("Biometric session already valid")
            return
        }
        
        let context = LAContext()
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            logger.error("Biometric not available: \(error?.localizedDescription ?? "unknown")")
            throw SSHKeyError.secureEnclaveNotAvailable
        }
        
        let reason = "Authenticate to use SSH keys"
        
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            
            if success {
                isAuthenticated = true
                logger.info("Biometric authentication successful — session started")
            } else {
                logger.warning("Biometric authentication returned false")
                throw SSHKeyError.biometricAuthRequired
            }
        } catch {
            if let laError = error as? LAError, laError.code == .userCancel {
                logger.info("Biometric authentication cancelled by user")
            } else {
                logger.error("Biometric authentication failed: \(error.localizedDescription)")
            }
            throw SSHKeyError.biometricAuthRequired
        }
    }
    
    /// Invalidate the current biometric session.
    /// Called automatically when the app enters the background.
    func invalidateSession() {
        if isAuthenticated {
            isAuthenticated = false
            logger.info("Biometric session invalidated (app backgrounded)")
        }
    }
}
