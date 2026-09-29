//
//  EtcdKeyspace.swift
//  EtcdDriverPlugin
//

import Foundation

internal struct EtcdKeyspace: Equatable, Sendable {
    struct Table: Equatable, Sendable {
        let name: String
        let keyCount: Int
    }

    static let rootTableName = "(root)"

    private static let separator: Unicode.Scalar = "/"

    let root: String

    init(keyPrefixRoot: String) {
        let isBounded = keyPrefixRoot.isEmpty || keyPrefixRoot.unicodeScalars.last == Self.separator
        root = isBounded ? keyPrefixRoot : keyPrefixRoot + "/"
    }

    var keysOnlyListing: String {
        "get \(EtcdCommandArgument.quoted(root)) --prefix --keys-only"
    }

    func tableName(forKey key: String) -> String {
        let relative = relativeKey(key)
        let segmentStart = relative.first == Self.separator
            ? relative.index(after: relative.startIndex)
            : relative.startIndex
        guard let segmentEnd = relative[segmentStart...].firstIndex(of: Self.separator) else {
            return Self.rootTableName
        }
        return String(relative[...segmentEnd])
    }

    func tables(forKeys keys: [String]) -> [Table] {
        var keyCounts: [String: Int] = [:]
        for key in keys {
            keyCounts[tableName(forKey: key), default: 0] += 1
        }
        let rootKeyCount = keyCounts.removeValue(forKey: Self.rootTableName)
        let prefixTables = keyCounts
            .sorted { $0.key < $1.key }
            .map { Table(name: $0.key, keyCount: $0.value) }
        guard rootKeyCount != nil || prefixTables.isEmpty else { return prefixTables }
        return [Table(name: Self.rootTableName, keyCount: rootKeyCount ?? 0)] + prefixTables
    }

    func prefix(forTable table: String) -> String {
        table == Self.rootTableName ? root : root + table
    }

    func exportQuery(forTable table: String) -> String {
        "get \(EtcdCommandArgument.quoted(prefix(forTable: table))) --prefix"
    }

    func dropStatement(forTable table: String) -> String? {
        let prefix = prefix(forTable: table)
        let coversWholeRoot = prefix == root
        guard !coversWholeRoot else { return nil }
        return "del \(EtcdCommandArgument.quoted(prefix)) --prefix"
    }

    func truncateStatements(forTable table: String) -> [String]? {
        dropStatement(forTable: table).map { [$0] }
    }

    private func relativeKey(_ key: String) -> Substring.UnicodeScalarView {
        let scalars = key[...].unicodeScalars
        guard scalars.starts(with: root.unicodeScalars) else { return scalars }
        return scalars.dropFirst(root.unicodeScalars.count)
    }
}
