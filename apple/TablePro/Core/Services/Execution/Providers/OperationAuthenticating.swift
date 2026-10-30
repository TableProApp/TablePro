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
        // A caller that gives up invalidates the context, which cancels the evaluation and dismisses its prompt.
        nonisolated(unsafe) let context = LAContext()
        do {
            return try await withTaskCancellationHandler {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } onCancel: {
                context.invalidate()
            }
        } catch {
            Self.logger.warning("Biometric authentication failed: \(error.publicLogShape, privacy: .public)")
            return false
        }
    }
}
