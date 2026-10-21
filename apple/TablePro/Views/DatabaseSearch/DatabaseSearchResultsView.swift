//
//  DatabaseSearchResultsView.swift
//  TablePro
//

import SwiftUI

internal struct DatabaseSearchResultsView: View {
    @ObservedObject internal var session: DatabaseSearchSession
    internal let onOpen: (DatabaseSearchTableResult) -> Void

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            results
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var status: some View {
        if session.step == .searching {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: session.progressFraction)
                    .progressViewStyle(.linear)
                Text(DatabaseSearchSummary.progress(
                    current: session.currentTarget,
                    completed: session.completedCount,
                    total: session.totalCount
                ))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("database-search-progress")
        } else {
            Text(DatabaseSearchSummary.finished(
                term: session.searchedOptions?.trimmedTerm ?? "",
                matchedTables: session.matchedResults.count,
                failedTables: session.failedResults.count,
                completed: session.completedCount,
                total: session.totalCount,
                wasStopped: session.wasStopped
            ))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("database-search-summary")
        }
    }

    @ViewBuilder
    private var results: some View {
        if session.listedResults.isEmpty {
            if session.step == .finished {
                UnavailableStateView {
                    Label(String(localized: "No Matches"), systemImage: "magnifyingglass")
                } description: {
                    Text(String(localized: "No searched column holds this value."))
                }
            } else {
                Spacer(minLength: 0)
            }
        } else {
            List(session.listedResults, selection: $session.selectedResultId) { result in
                DatabaseSearchResultRow(result: result)
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                if let result = openable(ids) {
                    Button(String(localized: "Open")) { onOpen(result) }
                }
            } primaryAction: { ids in
                if let result = openable(ids) { onOpen(result) }
            }
            .accessibilityIdentifier("database-search-results")
        }
    }

    private func openable(_ ids: Set<String>) -> DatabaseSearchTableResult? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return session.results.first { $0.id == id && $0.match != nil }
    }
}

private struct DatabaseSearchResultRow: View {
    let result: DatabaseSearchTableResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result.failure == nil ? "tablecells" : "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.target.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let match = result.match {
                Text(DatabaseSearchSummary.rowCount(match))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(result.failure ?? "")
    }

    private var detail: String {
        if let failure = result.failure {
            return failure
        }
        guard let match = result.match else { return "" }
        return match.matchedColumns.joined(separator: ", ")
    }
}

internal enum DatabaseSearchSummary {
    internal static func progress(current: DatabaseSearchTarget?, completed: Int, total: Int) -> String {
        let counts = String(
            format: String(localized: "%1$@ of %2$@ tables"),
            completed.formatted(.number.grouping(.automatic)),
            total.formatted(.number.grouping(.automatic))
        )
        guard let current else { return counts }
        return String(format: String(localized: "Searching %1$@ (%2$@)"), current.displayName, counts)
    }

    internal static func rowCount(_ match: DatabaseSearchMatch) -> String {
        let count = match.rowCount.formatted(.number.grouping(.automatic))
        if match.isCapped {
            return String(format: String(localized: "%@+ rows"), count)
        }
        return match.rowCount == 1
            ? String(format: String(localized: "%@ row"), count)
            : String(format: String(localized: "%@ rows"), count)
    }

    internal static func finished(
        term: String,
        matchedTables: Int,
        failedTables: Int,
        completed: Int,
        total: Int,
        wasStopped: Bool
    ) -> String {
        let searched = wasStopped
            ? String(
                format: String(localized: "Stopped after %1$@ of %2$@ tables."),
                completed.formatted(.number.grouping(.automatic)),
                total.formatted(.number.grouping(.automatic))
            )
            : total == 1
                ? String(localized: "Searched 1 table.")
                : String(
                    format: String(localized: "Searched %@ tables."),
                    total.formatted(.number.grouping(.automatic))
                )
        let found = matchedTables == 1
            ? String(format: String(localized: "1 table holds “%@”."), term)
            : String(
                format: String(localized: "%1$@ tables hold “%2$@”."),
                matchedTables.formatted(.number.grouping(.automatic)),
                term
            )
        var parts = [searched, found]
        if failedTables > 0 {
            parts.append(failedTables == 1
                ? String(localized: "1 table could not be searched.")
                : String(
                    format: String(localized: "%@ tables could not be searched."),
                    failedTables.formatted(.number.grouping(.automatic))
                ))
        }
        return parts.joined(separator: " ")
    }
}
