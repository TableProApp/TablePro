import SwiftUI

struct PrincipalChangeReviewSheet: View {
    let statements: [SchemaStatement]
    let lockoutWarning: String?
    let onExecute: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var hasDestructiveStatements: Bool {
        statements.contains(where: \.isDestructive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let lockoutWarning {
                warningBanner(lockoutWarning)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(statements.enumerated()), id: \.offset) { _, statement in
                        statementRow(statement)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review SQL")
                .font(.headline)
            Text("These statements will run against the server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func statementRow(_ statement: SchemaStatement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if statement.isDestructive {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                Text(statement.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(statement.sql)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
        }
    }

    private var footer: some View {
        HStack {
            Button("Copy SQL") {
                ClipboardService.shared.writeText(
                    statements.map { $0.sql.hasSuffix(";") ? $0.sql : $0.sql + ";" }
                        .joined(separator: "\n")
                )
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Execute", role: hasDestructiveStatements ? .destructive : nil) {
                onExecute()
            }
        }
        .padding(16)
    }
}
