//
//  RoutineDebugSessionSource.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct RoutineDebugDriverHandle: Sendable {
    let driver: any PluginDatabaseDriver
    let close: @Sendable () -> Void
}

internal enum RoutineDebugError: LocalizedError, Equatable {
    case sessionEnded
    case needsSeparateConnection
    case unsupported
    case connectionChanged

    var errorDescription: String? {
        switch self {
        case .sessionEnded:
            return String(localized: "The debug session has ended.")
        case .needsSeparateConnection:
            return String(localized: "This connection can't open the separate sessions the debugger needs.")
        case .unsupported:
            return String(localized: "This connection's driver can't debug routines.")
        case .connectionChanged:
            return String(localized: "The connection was closed or reconnected while the debugger was starting. Start it again.")
        }
    }
}

// Dedicated connections for one debug session: never pooled, never health-pinged, no query timeout, all closed when it ends.
internal actor RoutineDebugSessionSource: PluginDebugSessionSource {
    typealias Opener = @Sendable () async throws -> RoutineDebugDriverHandle

    // A paused target waits on a person, so any statement timeout would end the session between two steps.
    static let queryTimeoutSeconds = 0

    private let opener: Opener
    // The connection's admission fence: false while its transport is being torn down or after it was replaced.
    private let admits: @Sendable () async -> Bool
    private var handles: [UUID: RoutineDebugDriverHandle] = [:]
    private var isClosed = false
    private var permitsCleanup = false

    init(admits: @escaping @Sendable () async -> Bool = { true }, opener: @escaping Opener) {
        self.admits = admits
        self.opener = opener
    }

    // Once the run is stopping, a session the plugin opens to end its target is let through the fence.
    func permitCleanup() {
        permitsCleanup = true
    }

    func openSession() async throws -> any PluginDatabaseDriver {
        let handle = try await dial()
        handles[UUID()] = handle
        return handle.driver
    }

    // On a driver of its own, never the person's session: a DDL statement there would commit a transaction they left
    // open. The driver sits with the session's others while it runs, so ending the session closes it too.
    func run(_ statements: [String]) async throws {
        let handle = try await dial()
        let id = UUID()
        handles[id] = handle
        defer { handles.removeValue(forKey: id)?.close() }
        for statement in statements {
            try Task.checkCancellation()
            guard !isClosed else { throw RoutineDebugError.sessionEnded }
            _ = try await handle.driver.execute(query: statement)
        }
    }

    private func dial() async throws -> RoutineDebugDriverHandle {
        try await checkAdmission()
        let handle = try await opener()
        // The session may have ended, or the connection closed its fence, while the driver was being dialed.
        do {
            try await checkAdmission()
        } catch {
            handle.close()
            throw error
        }
        return handle
    }

    private func checkAdmission() async throws {
        guard !isClosed else { throw RoutineDebugError.sessionEnded }
        guard !permitsCleanup else { return }
        guard await admits() else { throw RoutineDebugError.connectionChanged }
        guard !isClosed else { throw RoutineDebugError.sessionEnded }
    }

    func closeAll() {
        isClosed = true
        let closing = handles.values
        handles.removeAll()
        for handle in closing {
            handle.close()
        }
    }
}

extension RoutineDebugSessionSource {
    typealias ServerOpener = @MainActor @Sendable (DatabaseScope, Int) async throws -> DatabaseDriver

    // `generation` is the connection's admission generation when the start sheet opened.
    @MainActor
    static func live(
        scope: DatabaseScope,
        generation: Int,
        open: @escaping ServerOpener = dedicatedServerDriver
    ) -> RoutineDebugSessionSource {
        let connectionId = scope.connectionId
        return RoutineDebugSessionSource(admits: {
            await RoutineDebugSessions.shared.admits(connectionId, generation: generation)
        }) {
            let driver = try await open(scope, Self.queryTimeoutSeconds)
            guard let adapter = driver as? PluginDriverAdapter else {
                driver.disconnect()
                throw RoutineDebugError.unsupported
            }
            return RoutineDebugDriverHandle(driver: adapter.schemaPluginDriver) { adapter.disconnect() }
        }
    }

    // A second connection to an embedded engine opens a different, empty database, so those engines are refused.
    @MainActor
    static func dedicatedServerDriver(scope: DatabaseScope, queryTimeoutSeconds: Int) async throws -> DatabaseDriver {
        guard let session = DatabaseManager.shared.session(for: scope.connectionId) else {
            throw DatabaseError.notConnected
        }
        guard session.connection.type.supportsConnectionPooling else {
            throw RoutineDebugError.needsSeparateConnection
        }
        return try await MetadataConnectionPool.openServerDriver(
            for: scope,
            purpose: .session,
            queryTimeoutSeconds: queryTimeoutSeconds
        )
    }
}
