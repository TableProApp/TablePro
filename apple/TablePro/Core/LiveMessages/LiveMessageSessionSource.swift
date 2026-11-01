//
//  LiveMessageSessionSource.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct LiveMessageDriverHandle: Sendable {
    let driver: any PluginDatabaseDriver
    let close: @Sendable () -> Void
}

internal enum LiveMessageError: LocalizedError, Equatable {
    case ended
    case needsSeparateConnection
    case unsupported

    var errorDescription: String? {
        switch self {
        case .ended:
            return String(localized: "The live message view has closed.")
        case .needsSeparateConnection:
            return String(localized: "This connection can't open the separate session live messages need.")
        case .unsupported:
            return String(localized: "This connection's driver can't follow live messages.")
        }
    }
}

// The connections one subscription attempt opened: never pooled, never health-pinged, no query timeout, all closed together.
internal actor LiveMessageSessionSource: PluginLiveSessionSource {
    typealias Opener = @Sendable () async throws -> LiveMessageDriverHandle

    // A subscription waits on messages, not on a statement, so any timeout would end it between two messages.
    static let queryTimeoutSeconds = 0

    private let opener: Opener
    private var handles: [LiveMessageDriverHandle] = []
    private var isClosed = false

    init(opener: @escaping Opener) {
        self.opener = opener
    }

    func openSession() async throws -> any PluginDatabaseDriver {
        guard !isClosed else { throw LiveMessageError.ended }
        let handle = try await opener()
        // Closed while the driver was being dialed.
        guard !isClosed else {
            handle.close()
            throw LiveMessageError.ended
        }
        handles.append(handle)
        return handle.driver
    }

    func closeAll() {
        isClosed = true
        let closing = handles
        handles.removeAll()
        for handle in closing {
            handle.close()
        }
    }
}

extension LiveMessageSessionSource {
    // A second connection to an embedded engine opens a different, empty database, so those engines are refused.
    @MainActor
    static func live(scope: DatabaseScope) -> LiveMessageSessionSource {
        LiveMessageSessionSource {
            let driver = try await openDedicatedDriver(scope: scope)
            guard let adapter = driver as? PluginDriverAdapter else {
                driver.disconnect()
                throw LiveMessageError.unsupported
            }
            return LiveMessageDriverHandle(driver: adapter.schemaPluginDriver) { adapter.disconnect() }
        }
    }

    @MainActor
    private static func openDedicatedDriver(scope: DatabaseScope) async throws -> DatabaseDriver {
        guard let session = DatabaseManager.shared.session(for: scope.connectionId) else {
            throw DatabaseError.notConnected
        }
        guard session.connection.type.supportsConnectionPooling else {
            throw LiveMessageError.needsSeparateConnection
        }
        return try await MetadataConnectionPool.openServerDriver(
            for: scope,
            purpose: .session,
            queryTimeoutSeconds: queryTimeoutSeconds
        )
    }
}
