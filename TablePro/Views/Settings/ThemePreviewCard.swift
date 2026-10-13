import SwiftUI

/// A few lines of SQL and a few grid rows in a theme's colors: the only two surfaces a theme
/// colors. Slots the theme leaves out resolve in the theme's own appearance.
internal struct ThemePreviewCard: View {
    internal let theme: ThemeDefinition

    private struct Token {
        let text: String
        let slot: ThemeSlot
    }

    private struct GridCell {
        let text: String
        let slot: ThemeSlot
    }

    private static let codeLines: [[Token]] = [
        [Token(text: "-- Active customers", slot: .syntaxComment)],
        [
            Token(text: "SELECT", slot: .syntaxKeyword),
            Token(text: " name, ", slot: .editorText),
            Token(text: "COUNT", slot: .syntaxFunction),
            Token(text: "(*) ", slot: .editorText),
            Token(text: "AS", slot: .syntaxKeyword),
            Token(text: " orders", slot: .editorText),
        ],
        [
            Token(text: "FROM", slot: .syntaxKeyword),
            Token(text: " customers", slot: .editorText),
        ],
        [
            Token(text: "WHERE", slot: .syntaxKeyword),
            Token(text: " country ", slot: .editorText),
            Token(text: "=", slot: .syntaxOperator),
            Token(text: " 'VN' ", slot: .syntaxString),
            Token(text: "AND", slot: .syntaxKeyword),
            Token(text: " score ", slot: .editorText),
            Token(text: ">", slot: .syntaxOperator),
            Token(text: " 42", slot: .syntaxNumber),
        ],
        [
            Token(text: "  AND", slot: .syntaxKeyword),
            Token(text: " deleted_at ", slot: .editorText),
            Token(text: "IS", slot: .syntaxKeyword),
            Token(text: " NULL", slot: .syntaxNull),
            Token(text: "::", slot: .syntaxOperator),
            Token(text: "TIMESTAMP", slot: .syntaxType),
        ],
    ]

    private static let currentLine = 3
    private static let selectedLine = 2
    private static let selectedToken = 1

    private static let gridHeader = ["id", "name", "active"]
    private static let gridRows: [[GridCell]] = [
        [
            GridCell(text: "1", slot: .gridText),
            GridCell(text: "Ada", slot: .gridText),
            GridCell(text: "true", slot: .gridBoolTrue),
        ],
        [
            GridCell(text: "2", slot: .gridText),
            GridCell(text: "NULL", slot: .gridNullValue),
            GridCell(text: "false", slot: .gridBoolFalse),
        ],
        [
            GridCell(text: "3", slot: .gridText),
            GridCell(text: "Grace", slot: .gridText),
            GridCell(text: "true", slot: .gridBoolTrue),
        ],
    ]

    private static let selectedRow = 2
    private static let columnWidths: [CGFloat] = [28, 72, 56]

    internal var body: some View {
        VStack(spacing: 0) {
            editor
            grid
        }
        .font(.system(size: 11, design: .monospaced))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: String(localized: "Preview of %@"), theme.name))
    }

    private func color(_ slot: ThemeSlot) -> Color {
        Color(nsColor: theme.color(for: slot))
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.codeLines.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(verbatim: "\(index + 1)")
                        .foregroundStyle(color(.editorLineNumber))
                        .frame(width: 14, alignment: .trailing)
                    codeLine(index)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(index == Self.currentLine ? color(.editorCurrentLine) : Color.clear)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(.editorBackground))
    }

    private func codeLine(_ line: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Self.codeLines[line].indices, id: \.self) { index in
                let token = Self.codeLines[line][index]
                let isSelected = line == Self.selectedLine && index == Self.selectedToken
                Text(verbatim: token.text)
                    .foregroundStyle(color(token.slot))
                    .background(isSelected ? color(.editorSelection) : Color.clear)
            }
            if line == Self.currentLine {
                Rectangle()
                    .fill(color(.editorCursor))
                    .frame(width: 1.5, height: 12)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: - Grid

    private var grid: some View {
        VStack(spacing: 0) {
            gridRow(
                number: "",
                cells: Self.gridHeader.map { GridCell(text: $0, slot: .gridHeaderText) },
                background: color(.gridHeaderBackground)
            )
            gridLine
            ForEach(Self.gridRows.indices, id: \.self) { index in
                let isSelected = index == Self.selectedRow
                gridRow(
                    number: "\(index + 1)",
                    cells: Self.gridRows[index],
                    background: rowBackground(index),
                    textSlot: isSelected ? .gridSelectionText : nil
                )
                gridLine
            }
        }
        .background(color(.gridBackground))
    }

    private func rowBackground(_ index: Int) -> Color {
        if index == Self.selectedRow { return color(.gridSelection) }
        return index.isMultiple(of: 2) ? color(.gridBackground) : color(.gridAlternateRow)
    }

    private func gridRow(number: String, cells: [GridCell], background: Color, textSlot: ThemeSlot? = nil) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: number)
                .foregroundStyle(color(textSlot ?? .gridRowNumber))
                .frame(width: 22, alignment: .trailing)
                .padding(.trailing, 8)
            ForEach(cells.indices, id: \.self) { index in
                Text(verbatim: cells[index].text)
                    .foregroundStyle(color(textSlot ?? cells[index].slot))
                    .lineLimit(1)
                    .frame(width: Self.columnWidths[index], alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .background(background)
    }

    private var gridLine: some View {
        Rectangle()
            .fill(color(.gridLine))
            .frame(height: 1)
    }
}
