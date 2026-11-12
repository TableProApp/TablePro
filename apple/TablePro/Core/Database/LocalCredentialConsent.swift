//
//  LocalCredentialConsent.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit

internal struct LocalCredentialQuestion: Equatable, Sendable {
    let connectionName: String
    let uses: [String]
    let destination: String
    let origin: ConnectionOrigin
}

internal enum LocalCredentialConsentError: Error, Equatable, Sendable {
    case declined
    case unanswered
    case needsPerson
}

extension LocalCredentialConsentError: LocalizedError {
    internal var errorDescription: String? {
        switch self {
        case .declined:
            String(localized: "Signing in with credentials from this Mac was not approved.")
        case .unanswered:
            String(localized: "Nobody answered the sign-in prompt in time.")
        case .needsPerson:
            String(localized: "TablePro does not sign in to a new server with credentials from this Mac on its own.")
        }
    }

    internal var recoverySuggestion: String? {
        switch self {
        case .declined:
            nil
        case .unanswered:
            String(localized: "Try again and answer the prompt in TablePro.")
        case .needsPerson:
            String(localized: "Connect again to review the sign-in and approve it.")
        }
    }
}

// A gesture asks through `confirm` before its attempt, and the stored approval lets that connect sign in.
@MainActor
internal final class LocalCredentialConsent {
    internal typealias Ask = @MainActor (LocalCredentialQuestion) async -> ConsentAnswer

    internal static let shared = LocalCredentialConsent()

    private let approvals: ConnectionApprovalStore
    private let ask: Ask

    internal init(
        approvals: ConnectionApprovalStore = .localCredentials,
        ask: @escaping Ask = LocalCredentialPrompt.ask
    ) {
        self.approvals = approvals
        self.ask = ask
    }

    internal func requiresApproval(_ connection: DatabaseConnection) -> Bool {
        !approvals.isApproved(connection)
    }

    internal func confirm(_ connection: DatabaseConnection) async -> Bool {
        guard requiresApproval(connection) else { return true }
        guard await ask(Self.question(for: connection)) == .approved else { return false }
        approvals.approve(connection)
        return true
    }

    internal func check(_ connection: DatabaseConnection, trigger: ConnectTrigger) async throws {
        guard requiresApproval(connection) else { return }
        guard trigger == .request else { throw LocalCredentialConsentError.needsPerson }
        switch await ask(Self.question(for: connection)) {
        case .approved:
            approvals.approve(connection)
        case .declined:
            throw LocalCredentialConsentError.declined
        case .unanswered:
            throw LocalCredentialConsentError.unanswered
        }
    }

    internal static func question(for connection: DatabaseConnection) -> LocalCredentialQuestion {
        let fields = PluginMetadataRegistry.shared.snapshot(for: connection.type)?
            .connection.additionalConnectionFields ?? []
        return LocalCredentialQuestion(
            connectionName: connection.name,
            uses: ConnectionFieldCatalog.localCredentialUses(in: connection.additionalFields).map { use in
                describe(use, fields: fields)
            },
            destination: SSHProfileStorage.shared.refreshingLinkedProfile(connection).destinationSummary,
            origin: connection.origin
        )
    }

    // In the form's words where the plugin declares the field, so the person reads what they would have picked.
    internal static func describe(_ use: LocalCredentialUse, fields: [ConnectionField]) -> String {
        guard let field = fields.first(where: { $0.id == use.fieldId }) else {
            let name = ConnectionSecretOptions.mongoOption(in: use.fieldId) == nil
                ? use.fieldId
                : String(use.fieldId.dropFirst(ConnectionSecretOptions.mongoOptionPrefix.count))
            return labeled(name, use.value)
        }
        switch field.fieldType {
        case .dropdown(let options):
            return labeled(field.label, options.first { $0.value == use.value }?.label ?? use.value)
        case .toggle where use.value == "true":
            return field.label
        default:
            return labeled(field.label, use.value)
        }
    }

    private static func labeled(_ label: String, _ value: String) -> String {
        String(format: String(localized: "%@: %@"), label, value)
    }
}
