import SwiftUI

/// Sessions are server records, so they draw in the data grid and take its theme. The grid has no
/// per-row buttons, so Cancel and Terminate act on the selected session from the header.
internal struct SessionsTableView: View {
    @ObservedObject internal var viewModel: ServerDashboardViewModel
    @ObservedObject private var selection: StructureListSelection<String>
    @StateObject private var grid = StructureListGridModel<String>(
        accessibilityLabel: String(localized: "Active Sessions")
    )
    @State private var sortState = SessionGridColumns.defaultSort
    @State private var columnLayout = ColumnLayoutState()

    internal init(viewModel: ServerDashboardViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _selection = ObservedObject(wrappedValue: viewModel.sessionSelection)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            table
        }
    }

    private var header: some View {
        HStack {
            Label(String(localized: "Active Sessions"), systemImage: "person.2")
                .font(.headline)
            Text("(\(viewModel.sessions.count))")
                .foregroundStyle(.secondary)
            Spacer()
            if let error = viewModel.panelErrors[.activeSessions] {
                Label {
                    RevealedTextView(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
            sessionActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sessionActions: some View {
        let target = SessionGridColumns.actionTarget(selection.ids, in: viewModel.sessions)
        let cancellable = target.map(viewModel.canCancel) ?? false
        let killable = target.map(viewModel.canKill) ?? false
        return HStack(spacing: 4) {
            Button {
                guard let target else { return }
                viewModel.confirmCancelQuery(target)
            } label: {
                Image(systemName: "stop.circle")
            }
            .disabled(!cancellable)
            .help(String(localized: "Cancel Query"))
            .accessibilityLabel(target.map {
                String(format: String(localized: "Cancel query for session %@"), $0.id)
            } ?? String(localized: "Cancel Query"))

            Button {
                guard let target else { return }
                viewModel.confirmKillSession(target)
            } label: {
                // The red marks a live destructive action, so a disabled button keeps the standard glyph.
                if killable {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "xmark.circle")
                }
            }
            .disabled(!killable)
            .help(String(localized: "Terminate Session"))
            .accessibilityLabel(target.map {
                String(format: String(localized: "Terminate session %@"), $0.id)
            } ?? String(localized: "Terminate Session"))
        }
        .buttonStyle(.borderless)
    }

    private var table: some View {
        let rows = SessionGridColumns.sorted(viewModel.sessions, by: sortState).map(SessionGridColumns.row(for:))
        let selection = selection
        var hasher = Hasher()
        hasher.combine(rows)
        return StructureListGrid(
            model: grid,
            columns: SessionGridColumns.titles,
            defaultWidths: SessionGridColumns.widths,
            minimumWidths: SessionGridColumns.minimumWidths,
            contentKey: hasher.finalize(),
            rows: { rows },
            databaseType: viewModel.databaseType,
            selectedIDs: { selection.ids },
            select: { selection.ids = $0 },
            sortState: $sortState,
            columnLayout: $columnLayout
        )
    }
}

internal enum SessionGridColumns {
    internal static let stateColumn = 3
    internal static let durationColumn = 4

    internal static var titles: [String] {
        [
            String(localized: "PID"),
            String(localized: "User"),
            String(localized: "Database"),
            String(localized: "State"),
            String(localized: "Duration"),
            String(localized: "Query"),
        ]
    }

    internal static let widths: [CGFloat] = [70, 100, 100, 110, 80, 360]
    internal static let minimumWidths: [CGFloat] = [50, 60, 60, 60, 50, 120]

    // The longest-running session first, as the dashboard has always opened.
    internal static var defaultSort: SortState {
        SortState(
            columns: [SortColumn(columnIndex: durationColumn, direction: .descending, columnName: String(localized: "Duration"))],
            source: .user
        )
    }

    internal static func values(for session: DashboardSession) -> [String] {
        [session.id, session.user, session.database, session.state, session.duration, session.query]
    }

    internal static func row(for session: DashboardSession) -> StructureListRow<String> {
        var row = StructureListRow(id: session.id, values: values(for: session))
        row.tones[stateColumn] = stateTone(session.state)
        return row
    }

    internal static func stateTone(_ state: String) -> StructureListTone? {
        switch state.lowercased() {
        case "active", "running": return .positive
        case "idle": return .secondary
        case "idle in transaction": return .caution
        case "waiting", "locked": return .critical
        default: return nil
        }
    }

    // Duration sorts by its seconds: the drawn text is a formatted span.
    internal static func sorted(_ sessions: [DashboardSession], by state: SortState) -> [DashboardSession] {
        guard !state.columns.isEmpty else { return sessions }
        let keyed = sessions.enumerated().map { offset, session in
            (offset: offset, session: session, values: values(for: session))
        }
        return keyed.sorted { lhs, rhs in
            for column in state.columns where lhs.values.indices.contains(column.columnIndex) {
                let comparison = compare(lhs.session, rhs.session, lhs.values, rhs.values, column: column.columnIndex)
                guard comparison != .orderedSame else { continue }
                return column.direction == .ascending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
            return lhs.offset < rhs.offset
        }
        .map(\.session)
    }

    // Cancel and Terminate name one session, so several selected rows have no target.
    internal static func actionTarget(_ selectedIDs: Set<String>, in sessions: [DashboardSession]) -> DashboardSession? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return sessions.first { $0.id == id }
    }

    private static func compare(
        _ lhs: DashboardSession,
        _ rhs: DashboardSession,
        _ lhsValues: [String],
        _ rhsValues: [String],
        column: Int
    ) -> ComparisonResult {
        guard column == durationColumn else {
            return lhsValues[column].localizedStandardCompare(rhsValues[column])
        }
        if lhs.durationSeconds == rhs.durationSeconds { return .orderedSame }
        return lhs.durationSeconds < rhs.durationSeconds ? .orderedAscending : .orderedDescending
    }
}
