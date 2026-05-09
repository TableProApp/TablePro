//
//  BiometricAuthService.swift
//  TableProMobile
//

import Foundation
import LocalAuthentication
import os

@MainActor
final class BiometricAuthService {
    enum Availability: Sendable {
        case unavailable
        case faceID
        case touchID
        case opticID
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "BiometricAuth")

    var availability: Availability {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        case .none: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Use Passcode")
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            return false
        } catch {
            Self.logger.warning("Biometric auth failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
