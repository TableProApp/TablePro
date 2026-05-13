//
//  MarkdownView.swift
//  TablePro
//
//  Block-level markdown renderer backed by Foundation's AttributedString(markdown:)
//  for inline formatting and native SwiftUI views for block layout.
//

import AppKit
import SwiftUI

struct MarkdownView: View {
    let source: String
    @State private var cache = MarkdownDocumentCache()

    var body: some View {
        let blocks = cache.blocks(for: source)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block)
                    .equatable()
            }
        }
    }
}

@MainActor
final class MarkdownDocumentCache {
    private var lastSource: String = "\u{FFFF}"
    private var lastBlocks: [MarkdownBlock] = []

    func blocks(for source: String) -> [MarkdownBlock] {
        if source == lastSource { return lastBlocks }
        lastSource = source
        lastBlocks = MarkdownBlockParser.parse(source)
        return lastBlocks
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block
    }

    var body: some View {
        switch block.kind {
        case .paragraph(let text):
            Text(MarkdownInline.parse(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .header(let level, let text):
            Text(MarkdownInline.parse(text))
                .font(headerFont(for: level))
                .fontWeight(headerWeight(for: level))
                .padding(.top, level == 1 ? 6 : 4)
                .padding(.bottom, 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .codeBlock(let code, let language):
            AIChatCodeBlockView(code: code, language: language)
                .equatable()
        case .unorderedList(let items):
            MarkdownListView(items: items, style: .unordered)
        case .orderedList(let start, let items):
            MarkdownListView(items: items, style: .ordered(start: start))
        case .blockquote(let lines):
            MarkdownBlockquoteView(lines: lines)
        case .table(let headers, let alignments, let rows):
            MarkdownTableView(headers: headers, alignments: alignments, rows: rows)
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

    private func headerWeight(for level: Int) -> Font.Weight {
        level <= 2 ? .bold : .semibold
    }
}

// MARK: - List

private struct MarkdownListView: View {
    let items: [MarkdownListItem]
    let style: ListStyle

    enum ListStyle: Equatable {
        case unordered
        case ordered(start: Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(marker(for: index))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MarkdownInline.parse(item.text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !item.children.isEmpty {
                            ForEach(item.children) { child in
                                MarkdownBlockView(block: child)
                                    .equatable()
                            }
                            .padding(.leading, 4)
                        }
                    }
                }
            }
        }
    }

    private func marker(for index: Int) -> String {
        switch style {
        case .unordered:
            return "•"
        case .ordered(let start):
            return "\(start + index)."
        }
    }
}

// MARK: - Blockquote

private struct MarkdownBlockquoteView: View {
    let lines: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 3)
            Text(MarkdownInline.parse(lines))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Table

private struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]

    var body: some View {
        let columnCount = headers.count
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { col in
                    cell(text: headers[col], alignment: alignments[safe: col] ?? .left)
                        .fontWeight(.semibold)
                }
            }
            Divider().gridCellColumns(columnCount)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { col in
                        cell(text: row[safe: col] ?? "", alignment: alignments[safe: col] ?? .left)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func cell(text: String, alignment: MarkdownTableAlignment) -> some View {
        let attributed = MarkdownInline.parse(text)
        switch alignment {
        case .left:
            Text(attributed).frame(maxWidth: .infinity, alignment: .leading)
        case .center:
            Text(attributed).frame(maxWidth: .infinity, alignment: .center)
        case .right:
            Text(attributed).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Inline parsing

enum MarkdownInline {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 4_000
        return c
    }()

    static func parse(_ source: String) -> AttributedString {
        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return AttributedString(cached)
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let attributed: AttributedString
        if let parsed = try? AttributedString(markdown: source, options: options) {
            attributed = parsed
        } else {
            attributed = AttributedString(source)
        }
        cache.setObject(NSAttributedString(attributed), forKey: key)
        return attributed
    }
}

// MARK: - Block model

struct MarkdownBlock: Identifiable, Equatable {
    let id: Int
    let kind: Kind

    enum Kind: Equatable {
        case paragraph(String)
        case header(level: Int, text: String)
        case codeBlock(code: String, language: String?)
        case unorderedList([MarkdownListItem])
        case orderedList(start: Int, items: [MarkdownListItem])
        case blockquote(String)
        case table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
        case thematicBreak
    }
}

struct MarkdownListItem: Identifiable, Equatable {
    let id: Int
    let text: String
    let children: [MarkdownBlock]
}

enum MarkdownTableAlignment: Equatable {
    case left
    case center
    case right
}

// MARK: - Parser

enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        while !lines.isEmpty {
            if let parsed = parseNextBlock(&lines, index: blocks.count) {
                blocks.append(parsed)
            }
        }
        return blocks
    }

    private static func parseNextBlock(_ lines: inout [String], index: Int) -> MarkdownBlock? {
        guard let first = lines.first else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            lines.removeFirst()
            return nil
        }

        if isFencedCodeStart(trimmed) {
            return parseFencedCodeBlock(&lines, index: index)
        }

        if let level = headerLevel(trimmed) {
            lines.removeFirst()
            let stripped = String(trimmed.dropFirst(level + 1))
                .trimmingCharacters(in: .whitespaces)
            return MarkdownBlock(id: index, kind: .header(level: level, text: stripped))
        }

        if isThematicBreak(trimmed) {
            lines.removeFirst()
            return MarkdownBlock(id: index, kind: .thematicBreak)
        }

        if trimmed.hasPrefix(">") {
            return parseBlockquote(&lines, index: index)
        }

        if isUnorderedListMarker(trimmed) {
            return parseUnorderedList(&lines, index: index)
        }

        if let start = orderedListStart(trimmed) {
            return parseOrderedList(&lines, startingAt: start, index: index)
        }

        if let table = parseTable(&lines, index: index) {
            return table
        }

        return parseParagraph(&lines, index: index)
    }

    private static func headerLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes <= 6,
              trimmed.count > hashes,
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: hashes)] == " "
        else { return nil }
        return hashes
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let collapsed = trimmed.replacingOccurrences(of: " ", with: "")
        guard collapsed.count >= 3 else { return false }
        return collapsed.allSatisfy { $0 == "-" }
            || collapsed.allSatisfy { $0 == "*" }
            || collapsed.allSatisfy { $0 == "_" }
    }

    private static func isFencedCodeStart(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func isUnorderedListMarker(_ trimmed: String) -> Bool {
        guard trimmed.count >= 2 else { return false }
        let first = trimmed.first
        let second = trimmed[trimmed.index(after: trimmed.startIndex)]
        return (first == "-" || first == "*" || first == "+") && second == " "
    }

    private static func orderedListStart(_ trimmed: String) -> Int? {
        let scanner = Scanner(string: trimmed)
        scanner.charactersToBeSkipped = nil
        var value: Int = 0
        guard scanner.scanInt(&value) else { return nil }
        guard scanner.scanString(".") != nil else { return nil }
        guard scanner.scanString(" ") != nil else { return nil }
        return value
    }

    private static func parseFencedCodeBlock(_ lines: inout [String], index: Int) -> MarkdownBlock {
        let opener = lines.removeFirst()
        let trimmedOpener = opener.trimmingCharacters(in: .whitespaces)
        let fence = trimmedOpener.hasPrefix("```") ? "```" : "~~~"
        let language: String? = {
            let info = String(trimmedOpener.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return info.isEmpty ? nil : info
        }()
        var bodyLines: [String] = []
        while let line = lines.first {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                lines.removeFirst()
                break
            }
            bodyLines.append(line)
            lines.removeFirst()
        }
        return MarkdownBlock(id: index, kind: .codeBlock(code: bodyLines.joined(separator: "\n"), language: language))
    }

    private static func parseBlockquote(_ lines: inout [String], index: Int) -> MarkdownBlock {
        var collected: [String] = []
        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            let content = trimmed.dropFirst()
                .trimmingCharacters(in: .whitespaces)
            collected.append(String(content))
            lines.removeFirst()
        }
        return MarkdownBlock(id: index, kind: .blockquote(collected.joined(separator: "\n")))
    }

    private static func parseUnorderedList(_ lines: inout [String], index: Int) -> MarkdownBlock {
        var items: [MarkdownListItem] = []
        while let item = parseListItem(&lines, ordered: false, itemIndex: items.count) {
            items.append(item)
        }
        return MarkdownBlock(id: index, kind: .unorderedList(items))
    }

    private static func parseOrderedList(_ lines: inout [String], startingAt start: Int, index: Int) -> MarkdownBlock {
        var items: [MarkdownListItem] = []
        while let item = parseListItem(&lines, ordered: true, itemIndex: items.count) {
            items.append(item)
        }
        return MarkdownBlock(id: index, kind: .orderedList(start: start, items: items))
    }

    private static func parseListItem(_ lines: inout [String], ordered: Bool, itemIndex: Int) -> MarkdownListItem? {
        guard let first = lines.first else { return nil }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        let markerLength: Int
        if ordered {
            guard orderedListStart(trimmed) != nil,
                  let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
            markerLength = trimmed.distance(from: trimmed.startIndex, to: dotIndex) + 2
        } else {
            guard isUnorderedListMarker(trimmed) else { return nil }
            markerLength = 2
        }
        let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: markerLength)
        var textLines: [String] = [String(trimmed[bodyStart...])]
        lines.removeFirst()

        while let next = lines.first {
            let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
            if nextTrimmed.isEmpty { break }
            if isUnorderedListMarker(nextTrimmed) || orderedListStart(nextTrimmed) != nil { break }
            if next.hasPrefix("    ") || next.hasPrefix("\t") {
                textLines.append(next.trimmingCharacters(in: .whitespaces))
                lines.removeFirst()
                continue
            }
            break
        }
        return MarkdownListItem(id: itemIndex, text: textLines.joined(separator: " "), children: [])
    }

    private static func parseTable(_ lines: inout [String], index: Int) -> MarkdownBlock? {
        guard lines.count >= 2 else { return nil }
        let headerLine = lines[0]
        let separatorLine = lines[1]
        guard headerLine.contains("|"), isTableSeparator(separatorLine) else { return nil }

        let headers = splitTableRow(headerLine)
        let alignments = parseTableAlignments(separatorLine)
        guard !headers.isEmpty, headers.count == alignments.count else { return nil }

        lines.removeFirst(2)
        var rows: [[String]] = []
        while let line = lines.first, looksLikeTableRow(line, columnCount: headers.count) {
            let row = splitTableRow(line)
            var padded = row
            while padded.count < headers.count { padded.append("") }
            rows.append(Array(padded.prefix(headers.count)))
            lines.removeFirst()
        }
        return MarkdownBlock(id: index, kind: .table(headers: headers, alignments: alignments, rows: rows))
    }

    private static func looksLikeTableRow(_ line: String, columnCount: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        guard trimmed.hasPrefix("|") || trimmed.hasSuffix("|") else { return false }
        let segments = splitTableRow(line)
        return segments.count >= max(2, columnCount - 1)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        let segments = splitTableRow(line)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            let inner = segment.trimmingCharacters(in: .whitespaces)
            guard !inner.isEmpty else { return false }
            return inner.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseTableAlignments(_ line: String) -> [MarkdownTableAlignment] {
        splitTableRow(line).map { segment in
            let inner = segment.trimmingCharacters(in: .whitespaces)
            let leadingColon = inner.hasPrefix(":")
            let trailingColon = inner.hasSuffix(":")
            switch (leadingColon, trailingColon) {
            case (true, true): return .center
            case (false, true): return .right
            default: return .left
            }
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseParagraph(_ lines: inout [String], index: Int) -> MarkdownBlock {
        var collected: [String] = []
        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if isFencedCodeStart(trimmed) { break }
            if headerLevel(trimmed) != nil { break }
            if isThematicBreak(trimmed) { break }
            if trimmed.hasPrefix(">") { break }
            if isUnorderedListMarker(trimmed) { break }
            if orderedListStart(trimmed) != nil { break }
            collected.append(line)
            lines.removeFirst()
        }
        return MarkdownBlock(id: index, kind: .paragraph(collected.joined(separator: "\n")))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
