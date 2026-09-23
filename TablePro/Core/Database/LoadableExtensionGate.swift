//
//  LoadableExtensionGate.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Decides which SQLite extensions a driver is handed, from one place every driver is built.
///
/// `DatabaseDriverFactory` asks this before any plugin sees the connection's fields, so a connect
/// from the window, a reconnect, a pooled metadata driver, MCP, AppleScript and Test Connection all
/// meet the same rule: a list the person has not approved on this Mac never reaches `dlopen`. The
/// prompt that records approval lives with the gestures (`LoadableExtensionPrompt`); this only
/// enforces it.
@MainActor
internal enum LoadableExtensionGate {
    /// The extension lists the connection's own form shows, decoded. A list whose field the form hides
    /// (a libSQL connection in Remote mode) is not part of the connection. A list that does not decode
    /// is left to the driver, which refuses it before it loads anything.
    internal static func declaredExtensions(
        for connection: DatabaseConnection,
        fields: [ConnectionField]? = nil
    ) -> [LoadableExtension] {
        let fields = fields ?? PluginManager.shared.additionalConnectionFields(for: connection.type)
        return fields
            .filter { $0.content == .loadableExtensions && fields.isVisible($0, forValues: connection.additionalFields) }
            .flatMap { (try? LoadableExtensionList.decode(connection.additionalFields[$0.id])) ?? [] }
    }

    /// The declared extensions this Mac has not approved for the connection. Empty for a live session
    /// on a server, where the driver refuses a list itself: asking would approve files that cannot load.
    internal static func pendingApproval(
        for connection: DatabaseConnection,
        fields: [ConnectionField]? = nil,
        approvals: LoadableExtensionApproving = LoadableExtensionApprovalStore.shared
    ) -> [LoadableExtension] {
        guard !runsOnServer(connection) else { return [] }
        return approvals.unapproved(declaredExtensions(for: connection, fields: fields), for: connection.id)
    }

    /// The fields a driver for `connection` is built with. Hidden extension lists are dropped, and a
    /// visible one this Mac has not approved stops the driver from being built at all.
    internal static func authorizedFields(
        _ additionalFields: [String: String],
        for connection: DatabaseConnection,
        fields: [ConnectionField]? = nil,
        approvals: LoadableExtensionApproving = LoadableExtensionApprovalStore.shared
    ) throws -> [String: String] {
        let fields = fields ?? PluginManager.shared.additionalConnectionFields(for: connection.type)
        var authorized = additionalFields
        for field in fields where field.content == .loadableExtensions
            && !fields.isVisible(field, forValues: connection.additionalFields) {
            authorized.removeValue(forKey: field.id)
        }
        let pending = pendingApproval(for: connection, fields: fields, approvals: approvals)
        guard pending.isEmpty else { throw LoadableExtensionApprovalError.notApproved(pending) }
        return authorized
    }

    private static func runsOnServer(_ connection: DatabaseConnection) -> Bool {
        connection.opensRemoteDatabaseSession
            || connection.additionalFields[RemoteSQLiteWire.backendFieldKey] == RemoteSQLiteWire.agentBackendValue
    }
}

internal enum LoadableExtensionApprovalError: Error, Equatable {
    case notApproved([LoadableExtension])
}

extension LoadableExtensionApprovalError: LocalizedError {
    internal var errorDescription: String? {
        String(localized: "This connection loads SQLite extensions that have not been approved on this Mac.")
    }

    internal var failureReason: String? {
        guard case .notApproved(let extensions) = self else { return nil }
        return extensions.map(\.path).joined(separator: "\n")
    }

    internal var recoverySuggestion: String? {
        String(localized: "Connect from the connection's window in TablePro to review them.")
    }
}
