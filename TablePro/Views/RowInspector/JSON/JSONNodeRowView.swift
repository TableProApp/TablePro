//
//  JSONNodeRowView.swift
//  TablePro
//
//  One printed line of the JSON inspector.
//

import AppKit
import SwiftUI

struct JSONNodeRowView: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    let row: JSONDisplayRow
    let colors: JSONRowColors
    let onToggle: () -> Void
    let onOpenReferencedTable: (JSONForeignKeyRef, String) -> Void
    /// Classified once per line that is drawn, for the swatch, the link and the menu alike.
    private let decoration: TreeValueDecoration

    private static let indentWidth: CGFloat = 14
    private static let controlWidth: CGFloat = 14

    /// A link in selectable text still opens through `openURL`, so this is the row's one way out
    /// to another app. It never answers `.systemAction`, which would open what the policy refused.
    static let openLink = OpenURLAction { url in
        if !isRepeatedClick { DataLinkPolicy.open(url) }
        return .handled
    }

    /// Both clicks of a double click land on the link, and the second one selects a word. The
    /// age check keeps an old event from swallowing an open that no click asked for.
    private static var isRepeatedClick: Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp, event.clickCount > 1 else { return false }
        return ProcessInfo.processInfo.systemUptime - event.timestamp < NSEvent.doubleClickInterval
    }

    init(
        row: JSONDisplayRow,
        colors: JSONRowColors,
        onToggle: @escaping () -> Void,
        onOpenReferencedTable: @escaping (JSONForeignKeyRef, String) -> Void
    ) {
        self.row = row
        self.colors = colors
        self.onToggle = onToggle
        self.onOpenReferencedTable = onOpenReferencedTable
        decoration = row.decoration
    }

    private var valueFont: Font { themeEngine.valueFontSwiftUI }

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
            scalarValue(scalar)
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

    @ViewBuilder
    private func scalarValue(_ scalar: JSONScalar) -> some View {
        if case .color(let color) = decoration {
            let capHeight = themeEngine.valueFont.capHeight
            JSONColorSwatch(color: color)
                .frame(width: TreeColorSwatchView.side, height: TreeColorSwatchView.side)
                /// A view with no text sits on the baseline by its bottom edge. This centers it on
                /// the capitals instead, which is where a glyph of the same size would sit.
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center] + capHeight / 2
                }
                .padding(.trailing, 4)
        }
        if case .link(let url) = decoration, case .string(let text) = scalar {
            Text(Self.linkedText(text, url: url, needsComma: row.needsComma))
                .font(valueFont)
                .foregroundStyle(colors.color(for: scalar))
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, Self.openLink)
                .accessibilityAction(named: Text(String(localized: "Open Link"))) {
                    DataLinkPolicy.open(url)
                }
        } else {
            Text(JSONScalarText.printed(scalar) + (row.needsComma ? "," : ""))
                .font(valueFont)
                .foregroundStyle(colors.color(for: scalar))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The printed string with the link over its characters only, so the quotes and the comma
    /// stay punctuation and a click on them opens nothing.
    static func linkedText(_ text: String, url: URL, needsComma: Bool) -> AttributedString {
        var value = AttributedString(JSONScalarText.escaped(text))
        value.link = url
        value.foregroundColor = Color(nsColor: .linkColor)
        value.swiftUI.underlineStyle = .single
        return AttributedString("\"") + value + AttributedString(needsComma ? "\"," : "\"")
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
        if case .link(let url) = decoration {
            Button(String(localized: "Open Link")) {
                DataLinkPolicy.open(url)
            }
            Button(String(localized: "Copy Link")) {
                copy(url.absoluteString)
            }
            Divider()
        }
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
        ClipboardService.shared.writeText(text)
    }
}

private struct JSONColorSwatch: NSViewRepresentable {
    let color: RGBAColor

    func makeNSView(context: Context) -> TreeColorSwatchView {
        TreeColorSwatchView()
    }

    func updateNSView(_ view: TreeColorSwatchView, context: Context) {
        view.color = color.nsColor
    }
}
