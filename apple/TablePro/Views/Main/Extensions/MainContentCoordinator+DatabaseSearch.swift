//
//  MainContentCoordinator+DatabaseSearch.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
extension MainContentCoordinator {
    var canSearchDatabase: Bool {
        DatabaseSearchEligibility.supportsSearch(connection.type)
    }

    // The database and schema travel with the request: the sidebar row the user right-clicked can be
    // a database the session is not browsing.
    func openDatabaseSearch(database: String?, schema: String?) {
        let launch = DatabaseSearchLaunchRequest(
            database: database?.nilIfEmpty ?? browseDatabaseName,
            schema: schema?.nilIfEmpty
        )
        activeSheet = .searchDatabase(databaseSearchSession(for: launch))
    }

    func databaseSearchSession(for launch: DatabaseSearchLaunchRequest) -> DatabaseSearchSession {
        if let existing = databaseSearchSession, existing.launch == launch {
            return existing
        }
        databaseSearchSession?.stop()
        let endpoint = DatabaseEndpoint.from(connection: connection, database: launch.database, schema: launch.schema)
        let dialect = try? resolveSQLDialect(for: connection.type)
        let session = DatabaseSearchSession(
            launch: launch,
            scopeDescription: endpoint.qualifiedDescription,
            caseMatching: .engine(dialect?.caseSensitivityStyle ?? .unsupported),
            reader: DatabaseSearchLiveReader(connection: connection, database: launch.database)
        )
        databaseSearchSession = session
        return session
    }

    func openDatabaseSearchResult(_ result: DatabaseSearchTableResult, in session: DatabaseSearchSession) {
        guard let match = result.match else { return }
        session.stop()
        activeSheet = nil
        openTabInNewWindow(makeDatabaseSearchResultPayload(
            target: result.target,
            match: match,
            database: session.launch.database
        ))
    }

    // Always a tab of its own: reusing an open tab of the table would write over the filters applied there.
    func makeDatabaseSearchResultPayload(
        target: DatabaseSearchTarget,
        match: DatabaseSearchMatch,
        database: String
    ) -> EditorTabPayload {
        EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: target.name,
            databaseName: database,
            schemaName: target.schema,
            isView: false,
            forcesNewTab: true,
            initialFilterState: match.filterState
        )
    }
}
