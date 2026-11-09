import SwiftUI

struct TableHealthPreviewPane: View {
    @ObservedObject var viewModel: TableHealthViewModel
    let databaseType: DatabaseType
    let actions: TableHealthActions

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
            Text(verbatim: finding.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            facts(finding)
            if let fix {
                SQLStatementPreview(
                    prepared: SQLReviewSheet.build(statements: [fix], databaseType: databaseType),
                    databaseType: databaseType
                )
                .id(finding.id)
                previewNote
            } else {
                Text("This finding has no SQL fix.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func facts(_ finding: TableHealthFinding) -> some View {
        if finding.sizeBytes != nil || !finding.metrics.isEmpty {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                if let size = finding.sizeBytes {
                    GridRow {
                        Text(verbatim: TableHealthColumn.size.title)
                            .foregroundStyle(.secondary)
                        Text(verbatim: ByteSizeFormatting.string(bytes: size))
                    }
                }
                ForEach(finding.metrics, id: \.id) { metric in
                    GridRow {
                        Text(verbatim: metric.label)
                            .foregroundStyle(.secondary)
                        Text(verbatim: metric.formattedValue)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
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
