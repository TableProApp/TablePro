//
//  ClickHouseSkippingIndexType.swift
//  ClickHouseDriverPlugin
//
//  The `TYPE` an `ALTER TABLE ... ADD INDEX` writes for a data skipping index.
//  Compiled into the test target via project.yml.
//

import Foundation

enum ClickHouseSkippingIndexType {
    /// The data skipping index types ClickHouse documents whose arguments are numbers, each with how
    /// many it takes: `minmax`, `set(max_rows)`, `bloom_filter([false_positive])`,
    /// `ngrambf_v1(n, size, hashes, seed)` and `tokenbf_v1(size, hashes, seed)`.
    private static let argumentCounts: [String: ClosedRange<Int>] = [
        "minmax": 0...0,
        "set": 1...1,
        "bloom_filter": 0...1,
        "ngrambf_v1": 4...4,
        "tokenbf_v1": 3...3
    ]

    /// What `TYPE` writes for `indexType`, or nil where it names no data skipping index.
    ///
    /// The structure editor hands over whatever type an index row holds, and that is open: a row read
    /// from this server says `DATA_SKIPPING`, a new one says `BTREE`, and a pasted one can say
    /// anything, which `TYPE` wrote verbatim. The name is written in the lowercase spelling
    /// ClickHouse documents. A nil type is the driver's own default, `minmax`.
    static func clause(for indexType: String?) -> String? {
        guard let indexType else { return "minmax" }
        let trimmed = indexType.trimmingCharacters(in: .whitespaces)
        let nameEnd = trimmed.firstIndex(of: "(") ?? trimmed.endIndex
        let name = trimmed[..<nameEnd].lowercased()
        guard let allowedCounts = argumentCounts[name],
              let arguments = numericArguments(trimmed[nameEnd...]),
              allowedCounts.contains(arguments.count) else { return nil }
        return arguments.isEmpty ? name : "\(name)(\(arguments.joined(separator: ", ")))"
    }

    private static func numericArguments(_ text: Substring) -> [String]? {
        guard !text.isEmpty else { return [] }
        guard text.hasPrefix("("), text.hasSuffix(")") else { return nil }
        let arguments = text.dropFirst().dropLast()
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard arguments.allSatisfy(isDecimalLiteral) else { return nil }
        return arguments
    }

    private static func isDecimalLiteral(_ text: String) -> Bool {
        let isDigitsAndPoint = text.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
        return isDigitsAndPoint && Double(text) != nil
    }
}
