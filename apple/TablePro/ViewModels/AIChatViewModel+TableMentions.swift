//
//  AIChatViewModel+TableMentions.swift
//  TablePro
//

import Combine
import Foundation

struct TableMentionIndex: Sendable {
    static let empty = TableMentionIndex(sortedNames: [])

    let names: [String]
    private let foldedNames: [[UInt8]?]

    private init(sortedNames: [String]) {
        names = sortedNames
        foldedNames = sortedNames.map(Self.asciiFolded)
    }

    init(tables: [TableInfo]) {
        var seen = Set<String>()
        let unique = tables.map(\.name).filter { seen.insert($0).inserted }
        self.init(sortedNames: unique.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    // Sorting and folding a large catalog takes up to a second.
    @concurrent
    static func build(from tables: [TableInfo]) async -> TableMentionIndex {
        TableMentionIndex(tables: tables)
    }

    // The names are already sorted, so the first `limit` matches are the ones a sort of every match
    // would keep.
    func names(matching query: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        guard !query.isEmpty else { return Array(names.prefix(limit)) }
        let needle = Self.asciiFolded(query)
        var matches: [String] = []
        for offset in names.indices {
            let isMatch = if let needle, let haystack = foldedNames[offset] {
                Self.contains(haystack, needle)
            } else {
                names[offset].localizedCaseInsensitiveContains(query)
            }
            guard isMatch else { continue }
            matches.append(names[offset])
            if matches.count == limit { break }
        }
        return matches
    }

    // Only ASCII folds to ASCII one character for one, which is where a byte search finds what
    // `localizedCaseInsensitiveContains` finds; `ß` folds to `ss` and would match `weis`.
    private static func asciiFolded(_ text: String) -> [UInt8]? {
        guard text.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        let folded = Array(text.folding(options: .caseInsensitive, locale: .current).utf8)
        return folded.allSatisfy { $0 < 0x80 } ? folded : nil
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard let first = needle.first else { return true }
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == first {
            var matched = 1
            while matched < needle.count, haystack[start + matched] == needle[matched] {
                matched += 1
            }
            if matched == needle.count { return true }
        }
        return false
    }
}

extension AIChatViewModel {
    static let mentionMenuTableLimit = 100

    var mentionMenuTableNames: [String] {
        Array(tableMentions.names.prefix(Self.mentionMenuTableLimit))
    }

    var hasUnlistedMentionTables: Bool {
        tableMentions.names.count > Self.mentionMenuTableLimit
    }

    // Started by the panel, so a session whose assistant is never shown never indexes its catalog.
    func trackTableMentions() {
        if tableMentionObservation == nil {
            tableMentionObservation = services.schemaService.$generations
                .map { _ in () }
                .merge(with: $connection.map { _ in () })
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshTableMentions() }
        }
        refreshTableMentions()
    }

    func refreshTableMentions() {
        let current = tables
        guard !Self.sameNames(current, tableMentionSource) else { return }
        tableMentionSource = current
        tableMentionBuild?.cancel()
        tableMentionBuild = Task { [weak self] in
            let index = await TableMentionIndex.build(from: current)
            guard !Task.isCancelled, let self else { return }
            self.tableMentions = index
            self.tableMentionBuild = nil
        }
    }

    // A reload hands over a new array of the same tables, and only the names show in a mention.
    private static func sameNames(_ lhs: [TableInfo], _ rhs: [TableInfo]) -> Bool {
        lhs.count == rhs.count && lhs.indices.allSatisfy { lhs[$0].name == rhs[$0].name }
    }
}
