//
//  DatabaseEndpointPickerModel.swift
//  TablePro
//
//  The databases and schemas the endpoint picker browses, loaded on demand and
//  kept for as long as the picker's window is open.
//
//  Reaching a database means connecting to its server, so a level loads only
//  once the user opens it, never because a pointer passed over it. A failure is
//  kept as a failure: an empty list and an unreachable server are not the same
//  answer, and remembering the second as the first is how a picker tells a user
//  their server has no databases.
//

import Foundation

internal enum DatabaseEndpointListState: Equatable {
    case loading
    case loaded([String])
    case failed(String)
}

@MainActor
@Observable
internal final class DatabaseEndpointPickerModel {
    private var databaseStates: [UUID: DatabaseEndpointListState] = [:]
    private var schemaStates: [String: DatabaseEndpointListState] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private let databaseLoader: (DatabaseConnection) async throws -> [String]
    @ObservationIgnored private let schemaLoader: (DatabaseEndpoint, DatabaseConnection) async throws -> [String]

    internal convenience init() {
        let metadata = CompareMetadataService()
        self.init(
            databaseLoader: { try await metadata.databases(for: $0) },
            schemaLoader: { try await metadata.schemas(for: $0, connection: $1) }
        )
    }

    internal init(
        databaseLoader: @escaping (DatabaseConnection) async throws -> [String],
        schemaLoader: @escaping (DatabaseEndpoint, DatabaseConnection) async throws -> [String]
    ) {
        self.databaseLoader = databaseLoader
        self.schemaLoader = schemaLoader
    }

    internal func databases(for connectionId: UUID) -> DatabaseEndpointListState {
        databaseStates[connectionId] ?? .loading
    }

    internal func schemas(for endpoint: DatabaseEndpoint) -> DatabaseEndpointListState {
        schemaStates[Self.schemaKey(endpoint)] ?? .loading
    }

    internal func loadDatabases(for connection: DatabaseConnection, reload: Bool = false) async {
        let key = "db|\(connection.id.uuidString)"
        guard shouldLoad(current: databaseStates[connection.id], key: key, reload: reload) else { return }
        defer { inFlight.remove(key) }

        beginLoading(&databaseStates[connection.id])
        do {
            databaseStates[connection.id] = .loaded(try await databaseLoader(connection))
        } catch {
            databaseStates[connection.id] = .failed(error.localizedDescription)
        }
    }

    internal func loadSchemas(
        for endpoint: DatabaseEndpoint,
        connection: DatabaseConnection,
        reload: Bool = false
    ) async {
        let mapKey = Self.schemaKey(endpoint)
        guard shouldLoad(current: schemaStates[mapKey], key: "schema|\(mapKey)", reload: reload) else { return }
        defer { inFlight.remove("schema|\(mapKey)") }

        beginLoading(&schemaStates[mapKey])
        do {
            schemaStates[mapKey] = .loaded(try await schemaLoader(endpoint, connection))
        } catch {
            schemaStates[mapKey] = .failed(error.localizedDescription)
        }
    }

    private func shouldLoad(current: DatabaseEndpointListState?, key: String, reload: Bool) -> Bool {
        if !reload, current != nil, !isFailed(current) { return false }
        return inFlight.insert(key).inserted
    }

    /// Only a level with nothing to show becomes a spinner. A reload keeps the list it is
    /// replacing on screen, so retrying never blanks a pane that already had an answer.
    private func beginLoading(_ state: inout DatabaseEndpointListState?) {
        guard state == nil || isFailed(state) else { return }
        state = .loading
    }

    private func isFailed(_ state: DatabaseEndpointListState?) -> Bool {
        guard case .failed = state else { return false }
        return true
    }

    private static func schemaKey(_ endpoint: DatabaseEndpoint) -> String {
        "\(endpoint.connectionId.uuidString)\u{1F}\(endpoint.database)"
    }
}
