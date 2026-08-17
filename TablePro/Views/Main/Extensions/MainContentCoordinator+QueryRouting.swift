import Foundation

/// What the caller wants done with a query it already has. Two cases rather than two flags,
/// because "run it, but in the tab already in front" is not a state any caller means, and a pair
/// of Bools would let one ask for it.
internal enum QueryOpenIntent {
    case loadIntoFrontTab
    case runInNewTab
}

extension MainContentCoordinator {
    /// The one route for "put this recorded SQL into an editor".
    ///
    /// The history drawer can list entries from connections this window does not host, so the
    /// connection that owns the query is named rather than assumed to be this one. A foreign query
    /// goes to its own connection's window, where the payload waits for a session if that
    /// connection is not open yet, instead of running against whatever is in front of the user.
    ///
    /// An empty `databaseName` means "wherever this connection is pointing", which is what a
    /// connection opened without a default database records; passing it through as a name would
    /// match no tab and open a second one. Running is refused while a confirmation is already up,
    /// because the gate would drop the dispatch and leave a tab whose query never ran.
    func openQuery(
        _ query: String,
        on owningConnectionId: UUID,
        databaseName: String?,
        intent: QueryOpenIntent
    ) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let targetDatabase = (databaseName?.isEmpty ?? true) ? nil : databaseName

        guard owningConnectionId == connectionId else {
            routeToOwningConnection(query, connectionId: owningConnectionId, databaseName: targetDatabase)
            return
        }

        guard intent == .runInNewTab else {
            guard loadQueryIntoEditor(query, databaseName: targetDatabase) == .currentCoordinator,
                  let tabId = tabManager.selectedTabId else { return }
            tabManager.pendingFocusTabId = tabId
            return
        }

        guard !isShowingSafeModePrompt else { return }

        tabManager.addTab(
            initialQuery: query,
            databaseName: targetDatabase ?? browseDatabaseName,
            claimFocus: true
        )
        runAllStatements(extraCapabilities: .confirmsWrites)
    }

    /// Deleting a connection deletes its query history with it, so an id that resolves to nothing
    /// means the two stores disagree. Say so, rather than opening a window onto a connection that
    /// is no longer there.
    private func routeToOwningConnection(_ query: String, connectionId owner: UUID, databaseName: String?) {
        guard connectionExists(owner) else {
            presentError(
                String(localized: "Could Not Open Query"),
                String(localized: "The connection this query was recorded against no longer exists."),
                contentWindow
            )
            return
        }

        openTabInNewWindow(
            EditorTabPayload(
                connectionId: owner,
                tabType: .query,
                databaseName: databaseName,
                initialQuery: query
            )
        )
    }
}
