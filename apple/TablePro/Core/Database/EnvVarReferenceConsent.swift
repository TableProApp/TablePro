//
//  EnvVarReferenceConsent.swift
//  TablePro
//

import Foundation

internal struct EnvVarReferenceQuestion: Equatable, Sendable {
    let connectionName: String
    let names: [String]
    let destination: String
    let origin: ConnectionOrigin
}

internal enum EnvVarReferenceConsentError: Error, Equatable, Sendable {
    case declined
    case unanswered
    case needsPerson
}

extension EnvVarReferenceConsentError: LocalizedError {
    internal var errorDescription: String? {
        switch self {
        case .declined:
            String(localized: "Sending this Mac's environment variables to the server was not approved.")
        case .unanswered:
            String(localized: "Nobody answered the environment variable prompt in time.")
        case .needsPerson:
            String(localized: "TablePro does not send environment variables to a new server on its own.")
        }
    }

    internal var recoverySuggestion: String? {
        switch self {
        case .declined:
            nil
        case .unanswered:
            String(localized: "Try again and answer the prompt in TablePro.")
        case .needsPerson:
            String(localized: "Connect again to review the variables and send them.")
        }
    }
}

// A gesture asks through `confirm` before its attempt, and the stored approval lets that connect resolve.
@MainActor
internal final class EnvVarReferenceConsent {
    internal typealias Ask = @MainActor (EnvVarReferenceQuestion) async -> ConsentAnswer

    private let approvals: ConnectionApprovalStore
    private let isFeatureAvailable: @MainActor () -> Bool
    private let ask: Ask

    internal init(
        approvals: ConnectionApprovalStore = .envVarReferences,
        isFeatureAvailable: @escaping @MainActor () -> Bool = {
            LicenseManager.shared.isFeatureAvailable(.envVarReferences)
        },
        ask: @escaping Ask = EnvVarReferencePrompt.ask
    ) {
        self.approvals = approvals
        self.isFeatureAvailable = isFeatureAvailable
        self.ask = ask
    }

    internal func requiresApproval(_ connection: DatabaseConnection) -> Bool {
        isFeatureAvailable() && !approvals.isApproved(connection)
    }

    internal func confirm(_ connection: DatabaseConnection) async -> Bool {
        guard requiresApproval(connection) else { return true }
        guard await ask(Self.question(for: connection)) == .approved else { return false }
        approvals.approve(connection)
        return true
    }

    internal func resolve(_ connection: DatabaseConnection, trigger: ConnectTrigger) async throws -> DatabaseConnection {
        guard isFeatureAvailable(), !EnvVarResolver.referencedNames(in: connection).isEmpty else { return connection }
        if approvals.isApproved(connection) {
            return EnvVarResolver.resolveConnection(connection)
        }
        guard trigger == .request else { throw EnvVarReferenceConsentError.needsPerson }
        switch await ask(Self.question(for: connection)) {
        case .approved:
            approvals.approve(connection)
            return EnvVarResolver.resolveConnection(connection)
        case .declined:
            throw EnvVarReferenceConsentError.declined
        case .unanswered:
            throw EnvVarReferenceConsentError.unanswered
        }
    }

    // The destination as stored, before resolution, so the prompt never shows a value it asks about.
    internal static func question(for connection: DatabaseConnection) -> EnvVarReferenceQuestion {
        EnvVarReferenceQuestion(
            connectionName: connection.name,
            names: EnvVarResolver.referencedNames(in: connection).sorted(),
            destination: connection.destinationSummary,
            origin: connection.origin
        )
    }
}
