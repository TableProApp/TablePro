import SwiftUI

/// Slow queries are server records, so they draw in the data grid and take its theme. The server's
/// order, slowest first, is kept: the drawn duration is a formatted span that would not sort.
internal struct SlowQueryListView: View {
    internal let queries: [DashboardSlowQuery]
    internal let error: String?
    internal let databaseType: DatabaseType

    @StateObject private var grid = StructureListGridModel<SlowQueryGridRows.RowID>(
        accessibilityLabel: String(localized: "Slow Queries")
    )
    @StateObject private var selection = StructureListSelection<SlowQueryGridRows.RowID>()
    @State private var columnLayout = ColumnLayoutState()

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(String(localized: "Slow Queries"), systemImage: "tortoise")
                    .font(.headline)
                Text("(\(queries.count))")
                    .foregroundStyle(.secondary)
                Spacer()
                if let error {
                    Label {
                        RevealedTextView(error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if queries.isEmpty && error == nil {
                Text(String(localized: "No slow queries"))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gridStandInBackground()
            } else {
                table
            }
        }
    }

    private var table: some View {
        let rows = SlowQueryGridRows.rows(for: queries)
        let selection = selection
        var hasher = Hasher()
        hasher.combine(rows)
        return StructureListGrid(
            model: grid,
            columns: SlowQueryGridRows.titles,
            defaultWidths: SlowQueryGridRows.widths,
            minimumWidths: SlowQueryGridRows.minimumWidths,
            contentKey: hasher.finalize(),
            rows: { rows },
            databaseType: databaseType,
            selectedIDs: { selection.ids },
            select: { selection.ids = $0 },
            sortState: nil,
            columnLayout: $columnLayout
        )
    }
}

internal enum SlowQueryGridRows {
    // A running query keeps its row across refreshes while its duration grows, so the duration is
    // not part of the identity; the same statement twice is told apart by its occurrence.
    internal struct RowID: Hashable {
        internal let statement: String
        internal let user: String
        internal let database: String
        internal let occurrence: Int
    }

    internal static var titles: [String] {
        [
            String(localized: "Duration"),
            String(localized: "Query"),
            String(localized: "User"),
            String(localized: "Database"),
        ]
    }

    internal static let durationColumn = 0
    internal static let widths: [CGFloat] = [80, 420, 100, 100]
    internal static let minimumWidths: [CGFloat] = [50, 120, 60, 60]

    internal static func rows(for queries: [DashboardSlowQuery]) -> [StructureListRow<RowID>] {
        var seen: [RowID: Int] = [:]
        return queries.map { query in
            let base = RowID(statement: query.query, user: query.user, database: query.database, occurrence: 0)
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            return StructureListRow(
                id: RowID(statement: query.query, user: query.user, database: query.database, occurrence: occurrence),
                values: [query.duration, query.query, query.user, query.database],
                tones: [durationColumn: .caution]
            )
        }
    }
}
