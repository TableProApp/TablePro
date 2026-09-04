//
//  AgentArtifactSchemaView.swift
//  TablePro
//

import SwiftUI

/// What a `CREATE`, `ALTER`, `DROP` or `TRUNCATE` the session proposed would change.
///
/// The preview is never the gate. A statement still runs only through its approval card and, when it
/// is destructive, only through `confirm_destructive_operation`. A statement the reader could not be
/// sure about shows its own SQL instead of a list, because a preview that missed a dropped column
/// would be worse than no preview.
internal struct AgentArtifactSchemaView: View {
    internal let changes: [SchemaChangePreview]

    internal var body: some View {
        List {
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 3) {
                    header(change)
                    if change.lines.isEmpty {
                        Text(String(localized: "TablePro could not read this statement's effect. Its SQL is above."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(change.lines) { line in
                            lineRow(line)
                        }
                    }
                }
                .padding(.vertical, 7)
                .contextMenu { CopySQLButton(sql: change.sql) }
            }
        }
        .listStyle(.inset)
    }

    private func header(_ change: SchemaChangePreview) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let target = change.target {
                    Text(target)
                        .font(.callout)
                        .bold()
                }
                if change.isDestructive {
                    StatusBadge(String(localized: "Destructive"), tint: .destructive)
                }
                Spacer()
            }
            Text(change.sql)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Each line names what it does rather than leaving it to a `+` or a `-` glyph. The colour and
    /// the icon are the same fact twice for a sighted reader and neither of them for anyone else.
    private func lineRow(_ line: SchemaChangeLine) -> some View {
        HStack(spacing: 0) {
            Label {
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(line.isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
            } icon: {
                Image(systemName: Self.icon(for: line.kind))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(line.isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(format: String(localized: "%1$@, %2$@"), Self.kindName(line.kind), line.text)
        )
    }

    private static func icon(for kind: SchemaChangeLine.Kind) -> String {
        switch kind {
        case .adds: return "plus.circle"
        case .removes: return "minus.circle"
        case .changes: return "arrow.triangle.2.circlepath"
        }
    }

    private static func kindName(_ kind: SchemaChangeLine.Kind) -> String {
        switch kind {
        case .adds: return String(localized: "Adds")
        case .removes: return String(localized: "Removes")
        case .changes: return String(localized: "Changes")
        }
    }
}
