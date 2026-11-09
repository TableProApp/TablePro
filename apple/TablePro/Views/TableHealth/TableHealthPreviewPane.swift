import SwiftUI

// The fix SQL is the pane's main content. The finding's detail and facts sit beside it, or under it in a capped
// scrolling area when the pane is too narrow, so they never push it out of view.
struct TableHealthPreviewPane: View {
    @ObservedObject var viewModel: TableHealthViewModel
    let databaseType: DatabaseType
    let actions: TableHealthActions

    @State private var aboutHeight: CGFloat = 0

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
                        about(finding)
                    }
                    .frame(width: TableHealthLayoutMetrics.previewAboutWidth)
                }
                VStack(alignment: .leading, spacing: 8) {
                    fixArea(fix, id: finding.id)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: TableHealthLayoutMetrics.previewSQLMinimumHeight,
                            maxHeight: .infinity
                        )
                    // A ScrollView takes all the height it is offered, so it gets the content's height up to the cap.
                    ScrollView {
                        about(finding)
                    }
                    .frame(height: min(aboutHeight, TableHealthLayoutMetrics.previewAboutMaximumHeight))
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

    // The whole detail: a warning such as the lock a type change takes must not be cut off.
    private func about(_ finding: TableHealthFinding) -> some View {
        let facts = Self.facts(of: finding)
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: finding.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !facts.isEmpty {
                Form {
                    ForEach(facts) { fact in
                        LabeledContent(fact.label) {
                            Text(verbatim: fact.value)
                        }
                    }
                }
                .formStyle(.columns)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            aboutHeight = height
        }
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
