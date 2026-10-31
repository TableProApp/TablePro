//
//  TableOptions.swift
//  TablePro
//

import Foundation

struct TableOptions: Hashable {
    var characterSet: String?
    var collation: String?
    /// Also rewrites every text column, not only the default later columns take. A read never sets it.
    var convertsColumns = false
    /// The value the next row takes, nil when the table has no AUTO_INCREMENT column.
    var autoIncrement: UInt64?

    /// Without the counter, so a counter edit never changes the staged character set change.
    var characterSetOnly: TableOptions {
        TableOptions(characterSet: characterSet, collation: collation, convertsColumns: convertsColumns)
    }

    func adoptingCharacterSet(of written: TableOptions) -> TableOptions {
        var copy = self
        copy.characterSet = written.characterSet
        copy.collation = written.collation
        copy.convertsColumns = false
        return copy
    }
}

/// A nil `original` means the read failed or the engine has none, so nothing stages.
struct TableOptionsDraft: Equatable {
    let original: TableOptions?
    var current: TableOptions?
    /// False from a save that wrote the counter until a read confirms it, since the server may have raised it.
    let isAutoIncrementConfirmed: Bool

    init(original: TableOptions?, isAutoIncrementConfirmed: Bool = true) {
        var loaded = original
        loaded?.convertsColumns = false
        self.original = loaded
        self.current = loaded
        self.isAutoIncrementConfirmed = isAutoIncrementConfirmed
    }

    var hasChanges: Bool {
        characterSetChange != nil || autoIncrementChange != nil
    }

    /// A convert to the table's own character set is still a change: it rewrites every column that differs.
    var characterSetChange: SchemaChange? {
        guard let original, let current else { return nil }
        guard current.convertsColumns
            || current.characterSet != original.characterSet
            || current.collation != original.collation else { return nil }
        return .modifyTableCharacterSet(old: original.characterSetOnly, new: current.characterSetOnly)
    }

    var autoIncrementChange: SchemaChange? {
        guard let original, let value = current?.autoIncrement, value != original.autoIncrement else { return nil }
        return .modifyAutoIncrement(old: original.autoIncrement, new: value)
    }
}

struct TableCharacterSet: Hashable, Identifiable {
    let name: String
    let defaultCollation: String
    let collations: [String]
    let description: String?

    var id: String { name }
}

/// What the server offers any table. Server-wide, so one read serves every table on the connection.
struct TableOptionsCatalog: Hashable {
    let characterSets: [TableCharacterSet]
    let engines: [String]
    let defaultEngine: String?

    func characterSet(named name: String) -> TableCharacterSet? {
        characterSets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func collations(for characterSet: String) -> [String] {
        self.characterSet(named: characterSet)?.collations ?? []
    }

    func defaultCollation(for characterSet: String) -> String? {
        self.characterSet(named: characterSet)?.defaultCollation
    }

    func characterSet(owning collation: String) -> TableCharacterSet? {
        characterSets.first { candidate in
            candidate.collations.contains { $0.caseInsensitiveCompare(collation) == .orderedSame }
        }
    }
}

enum ColumnTextType {
    /// National spellings are left out: MySQL 8.4 refuses `NVARCHAR(10) CHARACTER SET latin1` with ERROR 1064.
    static func takesCharacterSet(_ dataType: String) -> Bool {
        var words = baseWords(of: dataType)
        if words.count > 1, words.last == "BINARY" {
            words.removeLast()
        }
        return textSpellings.contains(words.joined(separator: " "))
    }

    private static func baseWords(of dataType: String) -> [String] {
        let base = dataType.prefix { $0 != "(" }
        return base.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static let textSpellings: Set<String> = [
        "CHAR", "CHARACTER", "VARCHAR", "CHARACTER VARYING", "CHAR VARYING",
        "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT", "LONG", "LONG VARCHAR",
        "ENUM", "SET"
    ]
}

enum AutoIncrementRange {
    static func maximum(forColumnType dataType: String) -> UInt64? {
        maximum(forColumnType: dataType, unsigned: false)
    }

    /// `unsigned` is the column's own flag, for a type read without the word.
    static func maximum(forColumnType dataType: String, unsigned: Bool) -> UInt64? {
        let words = dataType.uppercased().split { $0.isWhitespace || $0 == "(" || $0 == ")" }.map(String.init)
        guard let base = words.first else { return nil }
        if base == "SERIAL" { return UInt64.max }
        guard let bits = integerBits[base] else { return nil }
        let isUnsigned = unsigned || words.contains("UNSIGNED")
        return isUnsigned ? UInt64.max >> (64 - bits) : UInt64.max >> (65 - bits)
    }

    private static let integerBits: [String: Int] = [
        "TINYINT": 8, "INT1": 8, "BOOL": 8, "BOOLEAN": 8,
        "SMALLINT": 16, "INT2": 16,
        "MEDIUMINT": 24, "INT3": 24, "MIDDLEINT": 24,
        "INT": 32, "INTEGER": 32, "INT4": 32,
        "BIGINT": 64, "INT8": 64
    ]
}
