import Foundation

/// What the trash button is about to delete, said out loud.
///
/// The delete narrows by everything the drawer is showing: scope, source, outcome, date range and
/// the search text. The confirmation used to name only the scope and the date range, so at the
/// panel's own default filter it promised "this connection's query history" while quietly sparing
/// every table browse, row edit, import and MCP query. That is the wrong way round for something
/// with no undo, and the entries it spares are the ones most likely to hold a value the user
/// wanted gone.
internal enum HistoryClearSummary {
    /// True when the filter hides any recorded query, measured against everything on record rather
    /// than against the panel's defaults. The default source filter already hides five of the seven
    /// sources, which is exactly the case the old message got wrong.
    internal static func hidesRecordedQueries(
        sources: Set<QueryHistorySource>,
        outcome: QueryHistoryOutcome,
        dateRange: HistoryDateRange,
        searchText: String
    ) -> Bool {
        sources != Set(QueryHistorySource.allCases)
            || outcome != .any
            || dateRange != .all
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    internal static func message(
        showsAllConnections: Bool,
        sources: Set<QueryHistorySource>,
        outcome: QueryHistoryOutcome,
        dateRange: HistoryDateRange,
        searchText: String
    ) -> String {
        let narrowed = hidesRecordedQueries(
            sources: sources,
            outcome: outcome,
            dateRange: dateRange,
            searchText: searchText
        )

        guard narrowed else {
            return showsAllConnections
                ? String(localized: "This deletes the query history of every connection. You cannot undo this.")
                : String(localized: "This deletes this connection's query history. You cannot undo this.")
        }

        return showsAllConnections
            ? String(localized: """
                This deletes only the queries listed here, across every connection. Queries the \
                source, date, outcome and search filters are hiding stay. You cannot undo this.
                """)
            : String(localized: """
                This deletes only the queries listed here, from this connection. Queries the \
                source, date, outcome and search filters are hiding stay. You cannot undo this.
                """)
    }
}
