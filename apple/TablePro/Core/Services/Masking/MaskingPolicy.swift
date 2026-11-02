//
//  MaskingPolicy.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The rules one connection masks its values by, and the only place they are matched against columns.
struct MaskingPolicy: Equatable, Sendable {
    let rules: [MaskingRule]

    static let none = MaskingPolicy(rules: [])

    init(rules: [MaskingRule]) {
        self.rules = rules.filter { !$0.trimmedPattern.isEmpty }
    }

    var isEmpty: Bool { rules.isEmpty }

    /// The first rule that matches wins. Without a table, as for most query results, a `table.column`
    /// pattern matches by its column part alone, so an unknown source masks more rather than less.
    func style(table: String?, column: String, typeName: String?) -> MaskingStyle? {
        for rule in rules where Self.matches(rule, table: table, column: column, typeName: typeName) {
            return rule.style
        }
        return nil
    }

    func columnMasks(table: String?, columns: [String], typeNames: [String?]) -> ColumnMasks {
        guard !isEmpty else { return .none }
        var styles: [Int: MaskingStyle] = [:]
        for (index, column) in columns.enumerated() {
            let typeName = typeNames.indices.contains(index) ? typeNames[index] : nil
            if let style = style(table: table, column: column, typeName: typeName) {
                styles[index] = style
            }
        }
        return ColumnMasks(styles: styles)
    }

    func columnMasks(table: String?, columns: [String], columnTypes: [ColumnType]) -> ColumnMasks {
        columnMasks(table: table, columns: columns, typeNames: columnTypes.map(\.rawType))
    }

    private static func matches(_ rule: MaskingRule, table: String?, column: String, typeName: String?) -> Bool {
        let pattern = rule.trimmedPattern
        switch rule.target {
        case .type:
            guard let typeName else { return false }
            return MaskingGlob.matches(pattern, typeName)
        case .column:
            guard let dot = pattern.lastIndex(of: ".") else {
                return MaskingGlob.matches(pattern, column)
            }
            let tablePattern = String(pattern[..<dot])
            let columnPattern = String(pattern[pattern.index(after: dot)...])
            guard MaskingGlob.matches(columnPattern, column) else { return false }
            guard let table, !table.isEmpty else { return true }
            if MaskingGlob.matches(tablePattern, table) { return true }
            guard let bareStart = table.lastIndex(of: ".") else { return false }
            return MaskingGlob.matches(tablePattern, String(table[table.index(after: bareStart)...]))
        }
    }
}

/// `*` matches any run of characters and `?` exactly one, ignoring case.
enum MaskingGlob {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let text = Array(text.lowercased())
        var patternIndex = 0
        var textIndex = 0
        var starIndex: Int?
        var resumeIndex = 0
        while textIndex < text.count {
            if patternIndex < pattern.count, pattern[patternIndex] == "?" || pattern[patternIndex] == text[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                resumeIndex = textIndex
                patternIndex += 1
            } else if let star = starIndex {
                patternIndex = star + 1
                resumeIndex += 1
                textIndex = resumeIndex
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}

/// Which columns of one result are masked, and how. Every surface masks rows through this.
struct ColumnMasks: Equatable, Sendable {
    let styles: [Int: MaskingStyle]

    static let none = ColumnMasks(styles: [:])

    var isEmpty: Bool { styles.isEmpty }

    var maskedColumns: Set<Int> { Set(styles.keys) }

    func isMasked(_ column: Int) -> Bool {
        styles[column] != nil
    }

    func value(_ value: PluginCellValue, column: Int) -> PluginCellValue {
        guard let style = styles[column] else { return value }
        return MaskedValue.mask(value, style: style)
    }

    func row(_ values: [PluginCellValue]) -> [PluginCellValue] {
        guard !isEmpty else { return values }
        var masked = values
        for (column, style) in styles where column < masked.count {
            masked[column] = MaskedValue.mask(masked[column], style: style)
        }
        return masked
    }

    func rows(_ rows: [[PluginCellValue]]) -> [[PluginCellValue]] {
        guard !isEmpty else { return rows }
        return rows.map(row)
    }
}
