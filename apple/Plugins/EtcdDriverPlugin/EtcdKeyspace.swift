//
//  EtcdKeyspace.swift
//  EtcdDriverPlugin
//

import Foundation
import TableProEtcdCore

internal struct EtcdKeyspace: Equatable, Sendable {
    struct Table: Equatable, Sendable {
        let name: String
        let keyCount: Int
    }

    static let rootTableName = "(root)"

    private static let separator: Unicode.Scalar = "/"
    private static let separatorByte = UInt8(ascii: "/")

    let root: String

    init(keyPrefixRoot: String) {
        let isBounded = keyPrefixRoot.isEmpty || keyPrefixRoot.unicodeScalars.last == Self.separator
        root = isBounded ? keyPrefixRoot : keyPrefixRoot + "/"
    }

    var keysOnlyListing: String {
        EtcdCommandText.command("get", arguments: [Data(root.utf8)], flags: ["--prefix", "--keys-only"])
    }

    // A segment that is not UTF-8 has no table name that reads back as its bytes, so its key stays
    // under the root table, which lists every key below the root.
    func tableName(forKey key: Data) -> String {
        let relative = relativeKey(key)
        let segmentStart = relative.first == Self.separatorByte ? relative.index(after: relative.startIndex) : relative.startIndex
        guard let segmentEnd = relative[segmentStart...].firstIndex(of: Self.separatorByte),
              let name = EtcdCommandText.text(Data(relative[...segmentEnd])) else {
            return Self.rootTableName
        }
        return name
    }

    func count(_ keys: [Data], into keyCounts: inout [String: Int]) {
        for key in keys {
            keyCounts[tableName(forKey: key), default: 0] += 1
        }
    }

    func tables(fromKeyCounts counts: [String: Int]) -> [Table] {
        var keyCounts = counts
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
        EtcdCommandText.command("get", arguments: [Data(prefix(forTable: table).utf8)], flags: ["--prefix"])
    }

    func dropStatement(forTable table: String) -> String? {
        let prefix = prefix(forTable: table)
        let coversWholeRoot = prefix == root
        guard !coversWholeRoot else { return nil }
        return EtcdCommandText.command("del", arguments: [Data(prefix.utf8)], flags: ["--prefix"])
    }

    func truncateStatements(forTable table: String) -> [String]? {
        dropStatement(forTable: table).map { [$0] }
    }

    private func relativeKey(_ key: Data) -> Data {
        let rootBytes = Data(root.utf8)
        guard key.starts(with: rootBytes) else { return key }
        return key.dropFirst(rootBytes.count)
    }
}
