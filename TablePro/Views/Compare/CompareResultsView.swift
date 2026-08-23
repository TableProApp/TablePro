//
//  CompareResultsView.swift
//  TablePro
//
//  Every compared object in one table, grouped the way the session asks for.
//
//  Grouping produces real sections through `DisclosureTableRow`, and a section
//  header carries the include state of everything under it, so including a whole
//  difference class is one click rather than one per row.
//

import SwiftUI

internal struct CompareResultsView: View {
    @Bindable internal var session: CompareSyncSession
    internal let onCompare: () -> Void

    @State private var sortOrder = [KeyPathComparator(\CompareResultRow.objectName)]

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    internal var body: some View {
        let visible = session.visibleResults
        let uncomparable = session.report?.uncomparable ?? []
        if session.report == nil {
            noReportState
        } else if visible.isEmpty, uncomparable.isEmpty {
            emptyResultState
        } else {
            resultsTable(visible: visible, uncomparable: uncomparable)
        }
    }

    // MARK: - Table

    private func resultsTable(
        visible: [CompareObjectResult],
        uncomparable: [CompareObjectResult]
    ) -> some View {
        let groups = CompareResultGrouping.groups(
            from: visible, grouping: session.grouping, sortedUsing: sortOrder
        )
        let flatRows = CompareResultGrouping.rows(from: visible, sortedUsing: sortOrder)
        let unreadable = CompareResultGrouping.uncomparableGroup(from: uncomparable, sortedUsing: sortOrder)
        let selectableGroups = groups + (unreadable.map { [$0] } ?? [])

        return Table(of: CompareResultRow.self, selection: $session.selectedObjectId, sortOrder: $sortOrder) {
            TableColumn("Include") { row in
                includeToggle(for: row)
            }
            .width(min: 52, ideal: 60)

            TableColumn("Object", value: \.objectName) { row in
                Text(row.objectName)
                    .fontWeight(row.isGroup ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.objectName)
            }

            TableColumn("Type", value: \.typeName) { row in
                Text(row.typeName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TableColumn("Difference", value: \.differenceName) { row in
                differenceCell(row)
            }

            TableColumn("Change", value: \.changeSummary) { row in
                Text(row.changeSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.changeSummary)
            }
        } rows: {
            if session.grouping == .none {
                ForEach(flatRows) { row in
                    SwiftUI.TableRow(row)
                }
            } else {
                ForEach(groups) { group in
                    DisclosureTableRow(group.header) {
                        ForEach(group.rows) { row in
                            SwiftUI.TableRow(row)
                        }
                    }
                }
            }
            if let unreadable {
                DisclosureTableRow(unreadable.header) {
                    ForEach(unreadable.rows) { row in
                        SwiftUI.TableRow(row)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: CompareResultRow.ID.self) { selection in
            inclusionCommands(for: selection, groups: selectableGroups)
        }
    }

    @ViewBuilder
    private func inclusionCommands(for selection: Set<String>, groups: [CompareResultGroup]) -> some View {
        let ids = CompareResultGrouping.objectIds(in: selection, groups: groups)
        Button("Include") {
            session.setIncluded(true, forIds: ids)
        }
        .disabled(ids.isEmpty)
        Button("Exclude") {
            session.setIncluded(false, forIds: ids)
        }
        .disabled(ids.isEmpty)
    }

    // MARK: - Cells

    @ViewBuilder
    private func includeToggle(for row: CompareResultRow) -> some View {
        switch row.kind {
        case .group(let memberIds):
            Toggle(String(localized: "Include every object in this group"), isOn: groupInclusion(memberIds))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(memberIds.isEmpty)
                .accessibilityIdentifier("compare.results.includeGroup.\(row.id)")
        case .object(let result):
            Toggle(String(localized: "Include this object"), isOn: objectInclusion(result))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!result.isComparable || result.suggestedAction == .skip)
                .accessibilityIdentifier("compare.results.include.\(result.id)")
        }
    }

    @ViewBuilder
    private func differenceCell(_ row: CompareResultRow) -> some View {
        if let result = row.result {
            Label {
                Text(row.differenceName)
                    .lineLimit(1)
            } icon: {
                Image(systemName: symbolName(for: result))
            }
            .foregroundStyle(tint(for: result))
        }
    }

    private func symbolName(for result: CompareObjectResult) -> String {
        guard result.isComparable else { return "exclamationmark.triangle.fill" }
        return CompareStatusStyle.symbolName(for: result.status)
    }

    private func tint(for result: CompareObjectResult) -> Color {
        guard !differentiateWithoutColor else { return .primary }
        guard result.isComparable else { return CompareStatusStyle.warning }
        return CompareStatusStyle.tint(for: result.status)
    }

    // MARK: - Inclusion

    private func objectInclusion(_ result: CompareObjectResult) -> Binding<Bool> {
        Binding(
            get: { session.isIncluded(result) },
            set: { session.setIncluded($0, for: result) }
        )
    }

    private func groupInclusion(_ memberIds: [String]) -> Binding<Bool> {
        Binding(
            get: { !memberIds.isEmpty && memberIds.allSatisfy { session.actions[$0, default: .skip] != .skip } },
            set: { session.setIncluded($0, forIds: memberIds) }
        )
    }

    // MARK: - Empty states

    private var noReportState: some View {
        ContentUnavailableView {
            Label("No Comparison Yet", systemImage: "arrow.left.arrow.right.circle")
        } description: {
            Text("Choose a source and a target, then compare them.")
        } actions: {
            Button("Compare", action: onCompare)
                .disabled(!session.canCompare)
                .accessibilityIdentifier("compare.results.compare")
        }
    }

    @ViewBuilder
    private var emptyResultState: some View {
        if session.report?.differenceCount == 0 {
            ContentUnavailableView {
                Label("No Differences", systemImage: "equal.circle")
            } description: {
                Text("Every object that was compared matches.")
            } actions: {
                if !session.showsIdentical {
                    Button("Show Identical Objects") {
                        session.showsIdentical = true
                    }
                    .accessibilityIdentifier("compare.results.showIdentical")
                }
            }
        } else if !session.searchText.isEmpty {
            ContentUnavailableView.search(text: session.searchText)
        } else {
            ContentUnavailableView {
                Label("Nothing to Show", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("The object types taking part in the comparison are set in Options.")
            }
        }
    }
}
