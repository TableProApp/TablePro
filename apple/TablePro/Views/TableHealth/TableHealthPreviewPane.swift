import SwiftUI

// The fix SQL is the pane's main content: the facts sit beside it, or under it in one line each when the pane is
// too narrow, so they never push it out of view.
struct TableHealthPreviewPane: View {
    @ObservedObject var viewModel: TableHealthViewModel
    let databaseType: DatabaseType
    let actions: TableHealthActions

    private struct Fact: Identifiable {
        let id: String
        let label: String
        let value: String
    }

    var body: some View {
        let findings = viewModel.selectedFindings
        if findings.count == 1, let finding = findings.first {
            single(finding)
        } else if findings.count > 1 {
            several(findings)
        } else {
            Text("Select a finding to preview the SQL that fixes it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func single(_ finding: TableHealthFinding) -> some View {
        let fix = TableHealthViewModel.hasFix(finding) ? finding.fixSQL : nil
        let facts = Self.facts(of: finding)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: finding.qualifiedName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(String(localized: "Open Table")) { actions.openTable(finding) }
                    .disabled(finding.table == nil)
                Button(String(localized: "Copy")) {
                    if let fix { ClipboardService.shared.writeText(fix) }
                }
                .disabled(fix == nil)
                Button(String(localized: "Open in Editor")) {
                    if let fix { actions.openInEditor(fix) }
                }
                .disabled(fix == nil)
            }
            Text(verbatim: finding.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(finding.detail)
            if facts.isEmpty {
                fixArea(fix, id: finding.id)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        fixArea(fix, id: finding.id)
                            .frame(
                                minWidth: 0,
                                idealWidth: TableHealthLayoutMetrics.previewSQLIdealWidth,
                                maxWidth: .infinity,
                                maxHeight: .infinity
                            )
                        ScrollView {
                            factsColumn(facts)
                        }
                        .frame(width: TableHealthLayoutMetrics.previewFactsWidth)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        fixArea(fix, id: finding.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        factsGrid(facts)
                    }
                }
            }
            if fix != nil {
                previewNote
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func fixArea(_ fix: String?, id: TableHealthFindingID) -> some View {
        if let fix {
            SQLStatementPreview(
                prepared: SQLReviewSheet.build(statements: [fix], databaseType: databaseType),
                databaseType: databaseType
            )
            .id(id)
        } else {
            Text("This finding has no SQL fix.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Each label over its value, which wraps: a definition is longer than the column.
    private func factsColumn(_ facts: [Fact]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: fact.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: fact.value)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func factsGrid(_ facts: [Fact]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 2) {
            ForEach(facts) { fact in
                GridRow {
                    Text(verbatim: fact.label)
                        .foregroundStyle(.secondary)
                    Text(verbatim: fact.value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(fact.value)
                }
            }
        }
        .font(.callout)
    }

    private static func facts(of finding: TableHealthFinding) -> [Fact] {
        var facts: [Fact] = []
        if let size = finding.sizeBytes {
            facts.append(Fact(id: "size_bytes", label: TableHealthColumn.size.title, value: TableHealthColumn.byteSize(size)))
        }
        for metric in finding.metrics {
            let value: String
            if case .bytes(let bytes) = metric.value {
                value = TableHealthColumn.byteSize(bytes)
            } else {
                value = metric.formattedValue
            }
            facts.append(Fact(id: metric.id, label: metric.label, value: value))
        }
        return facts
    }

    private func several(_ findings: [TableHealthFinding]) -> some View {
        let fixCount = findings.filter(TableHealthViewModel.hasFix).count
        let script = viewModel.fixText(for: findings, databaseType: databaseType)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("^[\(fixCount) fix](inflect: true)")
                    .font(.headline)
                Spacer(minLength: 8)
                Button(String(localized: "Copy")) {
                    if let script { ClipboardService.shared.writeText(script) }
                }
                .disabled(script == nil)
                Button(String(localized: "Open in Editor")) {
                    if let script { actions.openInEditor(script) }
                }
                .disabled(script == nil)
            }
            if let script {
                SQLStatementPreview(
                    prepared: SQLReviewSheet.build(statements: [script], databaseType: databaseType, verbatim: true),
                    databaseType: databaseType
                )
                .id(script)
                previewNote
            } else {
                Text("The selected findings have no SQL fix.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
    }

    private var previewNote: some View {
        Text("This SQL is a preview. TablePro never runs it; review it in the editor and run it yourself.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
