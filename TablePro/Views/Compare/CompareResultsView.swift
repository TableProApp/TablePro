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
        VStack(spacing: 0) {
            CompareMessageBanner(session: session)
            filterBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
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

    /// Identical objects are hidden by default and the only way back used to be a button inside the
    /// empty state, which renders only when nothing differs at all. Nothing ever set it back, so the
    /// first press was permanent for the life of the window.
    private var filterBar: some View {
        HStack(spacing: 8) {
            Toggle("Show Identical Objects", isOn: $session.showsIdentical)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("compare.results.showIdentical")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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

    /// A group is three-valued, so it cannot be a `Toggle`: macOS has no mixed state for one. Five of
    /// six included used to render exactly like none included, and the first click then included the
    /// sixth rather than doing anything the checkbox appeared to offer.
    @ViewBuilder
    private func includeToggle(for row: CompareResultRow) -> some View {
        switch row.kind {
        case .group(let memberIds):
            if !memberIds.isEmpty {
                TristateCheckbox(
                    state: groupInclusionState(memberIds),
                    accessibilityLabel: String(localized: "Include every object in this group"),
                    accessibilityValue: groupInclusionValue(memberIds)
                ) {
                    session.setIncluded(groupInclusionState(memberIds) != .checked, forIds: memberIds)
                }
                .accessibilityIdentifier("compare.results.includeGroup.\(row.id)")
            }
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

    private func includedMemberCount(_ memberIds: [String]) -> Int {
        memberIds.filter { session.actions[$0, default: .skip] != .skip }.count
    }

    private func groupInclusionState(_ memberIds: [String]) -> TristateCheckbox.State {
        let included = includedMemberCount(memberIds)
        guard included > 0 else { return .unchecked }
        return included == memberIds.count ? .checked : .mixed
    }

    private func groupInclusionValue(_ memberIds: [String]) -> String {
        String(
            format: String(localized: "%1$d of %2$d included"),
            includedMemberCount(memberIds), memberIds.count
        )
    }

    // MARK: - Empty states

    /// The description says why Compare is unavailable when it is. A generic line over a dimmed
    /// button leaves the user with no way to work out what is missing, which the HIG asks an app not
    /// to do.
    private var noReportState: some View {
        ContentUnavailableView {
            Label("No Comparison Yet", systemImage: "arrow.left.arrow.right.circle")
        } description: {
            Text(noReportDescription)
        } actions: {
            Button("Compare", action: onCompare)
                .disabled(!session.canCompare)
                .accessibilityIdentifier("compare.results.compare")
        }
    }

    private var noReportDescription: String {
        session.compareDisabledReason
            ?? String(localized: "Choose a source and a target, then compare them.")
    }

    @ViewBuilder
    private var emptyResultState: some View {
        if session.report?.differenceCount == 0 {
            ContentUnavailableView {
                Label("No Differences", systemImage: "equal.circle")
            } description: {
                Text("Every object that was compared matches.")
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
