//
//  OperationAuthenticating.swift
//  TablePro
//

import LocalAuthentication
import os

internal protocol OperationAuthenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

internal struct BiometricOperationAuthenticating: OperationAuthenticating {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ExecutionGate")

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            Self.logger.warning("Biometric authentication failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
