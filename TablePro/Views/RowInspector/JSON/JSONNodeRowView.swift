//
//  JSONNodeRowView.swift
//  TablePro
//
//  One printed line of the JSON inspector.
//

import SwiftUI

struct JSONNodeRowView: View {
    let row: JSONDisplayRow
    let colors: JSONRowColors
    let onToggle: () -> Void
    let onOpenReferencedTable: (JSONForeignKeyRef, String) -> Void

    private static let indentWidth: CGFloat = 14
    private static let controlWidth: CGFloat = 14

    private var valueFont: Font { ThemeEngine.shared.valueFontSwiftUI }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Spacer()
                .frame(width: CGFloat(row.depth) * Self.indentWidth)
            disclosure
            content
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    // MARK: - Disclosure

    @ViewBuilder
    private var disclosure: some View {
        if row.isExpandable {
            Button(action: onToggle) {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.controlWidth, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                row.isExpanded ? String(localized: "Collapse") : String(localized: "Expand")
            )
        } else {
            Spacer().frame(width: Self.controlWidth)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if row.showsKey, let key = row.key.text {
                Text("\"\(JSONScalarText.escaped(key))\"")
                    .font(valueFont)
                    .foregroundStyle(colors.key)
                    .lineLimit(1)
                Text(": ")
                    .font(valueFont)
                    .foregroundStyle(colors.punctuation)
            }
            token
            status
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var token: some View {
        switch row.token {
        case .scalar(let scalar):
            Text(JSONScalarText.printed(scalar) + (row.needsComma ? "," : ""))
                .font(valueFont)
                .foregroundStyle(colors.color(for: scalar))
                .fixedSize(horizontal: false, vertical: true)
        case .openObject:
            punctuation("{")
        case .openArray:
            punctuation("[")
        case .closeObject:
            punctuation("}" + (row.needsComma ? "," : ""))
        case .closeArray:
            punctuation("]" + (row.needsComma ? "," : ""))
        case .collapsedObject(let count):
            collapsed(open: "{", close: "}", count: count)
        case .collapsedArray(let count):
            collapsed(open: "[", close: "]", count: count)
        }
    }

    private func punctuation(_ text: String) -> some View {
        Text(text)
            .font(valueFont)
            .foregroundStyle(colors.punctuation)
    }

    private func collapsed(open: String, close: String, count: Int) -> some View {
        HStack(spacing: 4) {
            punctuation(open)
            Text(count == 1
                ? String(localized: "1 item")
                : String(format: String(localized: "%d items"), count))
                .font(.caption)
                .foregroundStyle(colors.placeholder)
            punctuation(close + (row.needsComma ? "," : ""))
        }
    }

    @ViewBuilder
    private var status: some View {
        switch row.status {
        case .none:
            EmptyView()
        case .loading:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 16, height: 12)
                .padding(.leading, 4)
        case .failure(let failure):
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .help(Self.message(for: failure))
                .accessibilityLabel(Self.message(for: failure))
        }
    }

    static func message(for failure: JSONForeignKeyFailure) -> String {
        switch failure {
        case .notFound:
            String(localized: "Referenced row not found")
        case .cycle:
            String(localized: "This key references a row already shown above")
        case .depthLimit:
            String(
                format: String(localized: "Foreign keys are followed %d levels deep"),
                JSONForeignKeyExpansionPolicy.maxChainDepth
            )
        case .failed(let message):
            message
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private var menu: some View {
        if let scalar = row.scalar {
            Button(String(localized: "Copy Value")) {
                copy(JSONScalarText.unquoted(scalar))
            }
        }
        if let key = row.key.text {
            Button(String(localized: "Copy Key")) {
                copy(key)
            }
        }
        if let reference = row.foreignKey, let scalar = row.scalar, scalar != .null {
            Divider()
            Button(String(format: String(localized: "Open %@"), reference.qualifiedTable)) {
                onOpenReferencedTable(reference, JSONScalarText.unquoted(scalar))
            }
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
