//
//  ThemePreviewCard.swift
//  TablePro
//
//  Visual card showing a miniature preview of a theme's color palette.
//

import SwiftUI

struct ThemePreviewCard: View {
    enum CardSize {
        case standard
        case compact
    }

    let theme: ThemeDefinition
    let isActive: Bool
    let onSelect: () -> Void
    var size: CardSize = .standard

    var body: some View {
        switch size {
        case .standard:
            standardCard
        case .compact:
            compactCard
        }
    }

    // MARK: - Standard Card

    private var standardCard: some View {
        VStack(spacing: 4) {
            thumbnail
                .frame(width: 160, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 2.5)
                )
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

            VStack(spacing: 1) {
                Text(theme.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(theme.isBuiltIn
                    ? String(localized: "Built-in")
                    : String(localized: "Custom"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 160)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    // MARK: - Compact Card

    private var compactCard: some View {
        thumbnail
            .frame(width: 72, height: 45)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 0.5)
            )
    }

    // MARK: - Thumbnail

    private var sidebarStripWidth: CGFloat {
        size == .compact ? 22 : 28
    }

    private var codeLineHeight: CGFloat {
        size == .compact ? 2.5 : 3
    }

    private var dataGridRowCount: Int {
        size == .compact ? 2 : 3
    }

    private var dataGridHeight: CGFloat {
        size == .compact ? 14 : 28
    }

    private var thumbnail: some View {
        HStack(spacing: 0) {
            sidebarStrip
                .frame(width: sidebarStripWidth)

            VStack(spacing: 0) {
                editorArea
                dataGridArea
            }
        }
    }

    private var sidebarStrip: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(theme.sidebar.background?.swiftUIColor
                    ?? Color(nsColor: .windowBackgroundColor))

            VStack(alignment: .leading, spacing: size == .compact ? 3 : 4) {
                let widths: [CGFloat] = size == .compact
                    ? [10, 14, 13, 9]
                    : [14, 18, 17, 12]
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i == 1
                            ? (theme.sidebar.selectedItem?.swiftUIColor
                                ?? Color(nsColor: .selectedContentBackgroundColor)).opacity(0.6)
                            : (theme.sidebar.text?.swiftUIColor
                                ?? Color(nsColor: .labelColor)).opacity(0.25))
                        .frame(
                            width: widths[i],
                            height: codeLineHeight
                        )
                }
            }
            .padding(.top, size == .compact ? 5 : 8)
            .padding(.leading, size == .compact ? 3 : 4)
        }
    }

    private var editorArea: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(theme.editor.background.swiftUIColor)

            VStack(alignment: .leading, spacing: size == .compact ? 3 : 4) {
                if size == .compact {
                    codeLine(widths: [10, 16, 7],
                             colors: [theme.editor.syntax.keyword, theme.editor.syntax.function, theme.editor.syntax.type])
                    codeLine(widths: [7, 22],
                             colors: [theme.editor.syntax.keyword, theme.editor.syntax.string])
                    codeLine(widths: [13, 6, 9],
                             colors: [theme.editor.syntax.type, theme.editor.syntax.operator, theme.editor.syntax.number])
                } else {
                    codeLine(widths: [14, 22, 10],
                             colors: [theme.editor.syntax.keyword, theme.editor.syntax.function, theme.editor.syntax.type])
                    codeLine(widths: [10, 30],
                             colors: [theme.editor.syntax.keyword, theme.editor.syntax.string])
                    codeLine(widths: [18, 8, 12],
                             colors: [theme.editor.syntax.type, theme.editor.syntax.operator, theme.editor.syntax.number])
                    codeLine(widths: [26],
                             colors: [theme.editor.syntax.comment])
                }
            }
            .padding(.top, size == .compact ? 4 : 6)
            .padding(.leading, size == .compact ? 4 : 6)
        }
    }

    private func codeLine(widths: [CGFloat], colors: [String]) -> some View {
        HStack(spacing: size == .compact ? 2 : 3) {
            ForEach(Array(zip(widths, colors).enumerated()), id: \.offset) { _, pair in
                RoundedRectangle(cornerRadius: 1)
                    .fill(pair.1.swiftUIColor)
                    .frame(width: pair.0, height: codeLineHeight)
            }
        }
    }

    private var dataGridArea: some View {
        VStack(spacing: 0) {
            ForEach(0..<dataGridRowCount, id: \.self) { row in
                HStack(spacing: size == .compact ? 2 : 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(theme.dataGrid.text.swiftUIColor.opacity(0.3))
                            .frame(height: codeLineHeight)
                    }
                }
                .padding(.horizontal, size == .compact ? 3 : 4)
                .padding(.vertical, size == .compact ? 1 : 2)
                .background(row % 2 == 0
                    ? theme.dataGrid.background.swiftUIColor
                    : theme.dataGrid.alternateRow.swiftUIColor)
            }
        }
        .frame(height: dataGridHeight)
    }
}
