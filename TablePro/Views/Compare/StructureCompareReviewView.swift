//
//  StructureCompareReviewView.swift
//  TablePro
//
//  Differences grouped by object type or by operation, with the source and
//  target definitions side by side. Difference type never rests on colour alone.
//

import SwiftUI

internal enum CompareGrouping: String, CaseIterable {
    case byStatus
    case byName

    internal var title: String {
        switch self {
        case .byStatus: return String(localized: "Group by operation")
        case .byName: return String(localized: "Group by name")
        }
    }
}

internal struct StructureCompareReviewView: View {
    @Bindable internal var session: CompareSyncSession

    @State private var grouping: CompareGrouping = .byStatus
    @State private var showIdentical = false
    @State private var selection: String?

    internal var body: some View {
        HSplitView {
            treePane
                .frame(minWidth: 340, idealWidth: 420)
            detailPane
                .frame(minWidth: 360)
        }
    }

    private var report: StructureDiffReport? {
        session.structureReport
    }

    private var visibleResults: [TableDiffResult] {
        guard let report else { return [] }
        let base = showIdentical ? report.comparable : report.comparable.filter { $0.status != .identical }
        switch grouping {
        case .byName:
            return base.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        case .byStatus:
            return base.sorted { lhs, rhs in
                guard lhs.status == rhs.status else {
                    return statusRank(lhs.status) < statusRank(rhs.status)
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
        }
    }

    private func statusRank(_ status: TableDiffStatus) -> Int {
        switch status {
        case .onlyInSource: return 0
        case .differs: return 1
        case .onlyInTarget: return 2
        case .identical: return 3
        }
    }

    private var treePane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $grouping) {
                    ForEach(CompareGrouping.allCases, id: \.rawValue) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                Spacer()
                Toggle(String(localized: "Show identical"), isOn: $showIdentical)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(selection: $selection) {
                ForEach(visibleResults) { result in
                    CompareResultRow(result: result, session: session)
                        .tag(result.id)
                }

                if let uncomparable = report?.uncomparable, !uncomparable.isEmpty {
                    Section(String(localized: "Cannot be compared")) {
                        ForEach(uncomparable) { result in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.id)
                                Text(result.comparisonError ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            summaryBar
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 14) {
            if let report {
                statusCount(String(localized: "To create"), report.count(of: .onlyInSource), "plus.circle")
                statusCount(String(localized: "To alter"), report.count(of: .differs), "pencil.circle")
                statusCount(String(localized: "To drop"), report.count(of: .onlyInTarget), "minus.circle")
                statusCount(String(localized: "Identical"), report.count(of: .identical), "equal.circle")
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusCount(_ label: String, _ count: Int, _ symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text("\(label): \(count)")
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let result = visibleResults.first(where: { $0.id == selection }) {
            CompareResultDetailView(
                result: result,
                sourceSnapshot: session.sourceSnapshotCache[result.id],
                targetSnapshot: session.targetSnapshotCache[result.id]
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select a table to see what differs")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

internal struct CompareResultRow: View {
    internal let result: TableDiffResult
    @Bindable internal var session: CompareSyncSession

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    internal var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(statusLabel)
                    .font(.caption2)
                    .fixedSize()
            } icon: {
                Image(systemName: statusSymbol)
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(differentiateWithoutColor ? Color.primary : statusTint)
            .frame(width: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.tableName)
                if !result.notes.isEmpty {
                    Text(result.notes[0])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Picker("", selection: actionBinding) {
                ForEach(availableActions, id: \.rawValue) { action in
                    Text(actionTitle(action)).tag(action)
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }
        .padding(.vertical, 2)
    }

    private var actionBinding: Binding<TableSyncAction> {
        Binding(
            get: { session.action(for: result) },
            set: { session.setAction($0, for: result) }
        )
    }

    private var availableActions: [TableSyncAction] {
        switch result.status {
        case .onlyInSource: return [.skip, .create]
        case .onlyInTarget: return [.skip, .drop]
        case .differs: return [.skip, .alter]
        case .identical: return [.skip]
        }
    }

    private func actionTitle(_ action: TableSyncAction) -> String {
        switch action {
        case .create: return String(localized: "Create")
        case .alter: return String(localized: "Alter")
        case .drop: return String(localized: "Drop")
        case .skip: return String(localized: "Skip")
        }
    }

    private var statusLabel: String {
        switch result.status {
        case .onlyInSource: return String(localized: "Source only")
        case .onlyInTarget: return String(localized: "Target only")
        case .differs: return String(localized: "Different")
        case .identical: return String(localized: "Identical")
        }
    }

    private var statusSymbol: String {
        switch result.status {
        case .onlyInSource: return "plus.circle.fill"
        case .onlyInTarget: return "minus.circle.fill"
        case .differs: return "circle.lefthalf.filled"
        case .identical: return "equal.circle"
        }
    }

    private var statusTint: Color {
        switch result.status {
        case .onlyInSource: return .green
        case .onlyInTarget: return .red
        case .differs: return .orange
        case .identical: return .secondary
        }
    }
}

internal struct CompareResultDetailView: View {
    internal let result: TableDiffResult
    internal let sourceSnapshot: TableStructureSnapshot?
    internal let targetSnapshot: TableStructureSnapshot?

    internal var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(result.id)
                    .font(.headline)

                if !result.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                            Label(note, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let sourceSnapshot, let targetSnapshot {
                    StructureDefinitionDiffView(
                        sourceLines: TableDefinitionRenderer.lines(for: sourceSnapshot),
                        targetLines: TableDefinitionRenderer.lines(for: targetSnapshot)
                    )
                } else if let onlySide = sourceSnapshot ?? targetSnapshot {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sourceSnapshot == nil ? "Definition on the target" : "Definition on the source")
                            .font(.subheadline.weight(.semibold))
                        ForEach(TableDefinitionRenderer.lines(for: onlySide), id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                if result.changes.isEmpty {
                    Text("No structural changes.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Changes")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(result.changes.enumerated()), id: \.offset) { _, change in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: change.isDestructive ? "exclamationmark.triangle.fill" : "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(change.isDestructive ? Color.orange : Color.secondary)
                                Text(change.description)
                                    .font(.callout)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
