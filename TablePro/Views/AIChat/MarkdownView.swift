//
//  MarkdownView.swift
//  TablePro
//
//  Native SwiftUI views over a `MarkdownDocument`: one `Text` per paragraph, header and table cell, and the
//  chat's code block for fenced code.
//

import AppKit
import SwiftUI

struct MarkdownView: View, Equatable {
    let source: String
    var isStreaming: Bool = false

    var body: some View {
        MarkdownContent(source: source, isStreaming: isStreaming)
    }
}

private enum MarkdownMetrics {
    static let blockSpacing: CGFloat = 6
    static let listItemSpacing: CGFloat = 3
}

/// Owns the row's document model, which lives as long as the row does. A row the lazy stack drops takes its model
/// with it, and a parse finishing after that is discarded.
private struct MarkdownContent: View {
    let source: String
    let isStreaming: Bool

    @StateObject private var model: MarkdownDocumentModel

    init(source: String, isStreaming: Bool) {
        self.source = source
        self.isStreaming = isStreaming
        _model = StateObject(wrappedValue: MarkdownDocumentModel(source: source, isStreaming: isStreaming))
    }

    var body: some View {
        MarkdownBlockStack(blocks: model.document.blocks, isSettled: model.isSettled, spacing: MarkdownMetrics.blockSpacing)
            .onChange(of: source) { newSource in
                model.update(source: newSource, isStreaming: isStreaming)
            }
            .onChange(of: isStreaming) { newValue in
                model.update(source: source, isStreaming: newValue)
            }
    }
}

/// Only the last block of a reply still arriving can change, so only the blocks on that last path render unsettled.
private struct MarkdownBlockStack: View, Equatable {
    let blocks: [MarkdownBlock]
    let isSettled: Bool
    let spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, isSettled: isSettled || block.id != blocks.last?.id)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let isSettled: Bool

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .header(let level, let text):
            Text(text)
                .font(headerFont(for: level))
                .fontWeight(level <= 2 ? .bold : .semibold)
                .padding(.top, level == 1 ? 6 : 4)
                .padding(.bottom, 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .codeBlock(let code, let language):
            AIChatCodeBlockView(code: code, language: language, isSettled: isSettled)
                .equatable()
        case .list(let list):
            MarkdownListView(list: list, isSettled: isSettled)
        case .blockquote(let blocks):
            MarkdownBlockquoteView(blocks: blocks, isSettled: isSettled)
        case .table(let table):
            MarkdownTableView(table: table)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func headerFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

// MARK: - List

private struct MarkdownListView: View {
    let list: MarkdownList
    let isSettled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownMetrics.listItemSpacing) {
            ForEach(list.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(marker(for: item))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 16, alignment: .trailing)
                    MarkdownBlockStack(
                        blocks: item.blocks,
                        isSettled: isSettled || item.id != list.items.last?.id,
                        spacing: MarkdownMetrics.blockSpacing
                    )
                }
            }
        }
    }

    private func marker(for item: MarkdownListItem) -> String {
        guard let start = list.start else { return "•" }
        return "\(start + item.id)."
    }
}

// MARK: - Blockquote

private struct MarkdownBlockquoteView: View {
    let blocks: [MarkdownBlock]
    let isSettled: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 3)
            MarkdownBlockStack(blocks: blocks, isSettled: isSettled, spacing: MarkdownMetrics.blockSpacing)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Table

/// Wider than the pane, a table scrolls sideways. A horizontal scroll view passes vertical scrolling on to the
/// transcript, which the HIG allows for a scroll view of the other orientation.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.header[column], column: column)
                            .fontWeight(.semibold)
                    }
                }
                Divider().gridCellColumns(table.alignments.count)
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            cell(table.rows[row][column], column: column)
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func cell(_ text: AttributedString, column: Int) -> some View {
        let alignment: Alignment
        switch table.alignments.indices.contains(column) ? table.alignments[column] : .left {
        case .left: alignment = .leading
        case .center: alignment = .center
        case .right: alignment = .trailing
        }
        return Text(text).frame(maxWidth: .infinity, alignment: alignment)
    }
}
