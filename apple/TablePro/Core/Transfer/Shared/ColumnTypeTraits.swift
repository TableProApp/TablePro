import Foundation
import TableProPluginKit

// The two readings of a column type name an import needs, made as macOS `ColumnTypeClassifier` makes them for
// `.blob` and `.boolean`. `ColumnTypeTraitsTests` runs both over the same names.
nonisolated enum ColumnTypeTraits {
    // Oracle's `LONG RAW` holds bytes, and no pattern reads the name as binary.
    static let byteTypeNames: Set<String> = [
        "BLOB", "BYTEA", "BINARY", "VARBINARY", "RAW", "IMAGE", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB", "LONG RAW"
    ]

    private static let caseSensitiveBytesTypeName = "BYTES"

    static func holdsBytes(_ typeName: String) -> Bool {
        guard let shape = Shape(typeName) else { return false }
        if shape.base == caseSensitiveBytesTypeName { return true }
        let upper = shape.base.uppercased()
        if byteTypeNames.contains(upper) { return true }
        // The classifier tries these arms before it looks for BLOB inside a name.
        guard upper.contains("BLOB") else { return false }
        return !upper.contains("BOOL") && !upper.hasSuffix("SERIAL") && !upper.hasSuffix("INT")
            && !upper.hasPrefix("TIME") && !upper.hasSuffix("TEXT") && !upper.hasSuffix("CHAR")
    }

    // MySQL's `TINYINT(1)` is a flag on every engine, as the classifier reads it.
    static func isBooleanFlag(_ typeName: String, databaseTypeId: String) -> Bool {
        guard let shape = Shape(typeName) else { return false }
        let upper = shape.base.uppercased()
        if upper == "TINYINT", shape.params == "1" { return true }
        if upper == "BIT" { return bitIsFlag(shape, databaseTypeId: databaseTypeId) }
        return upper.contains("BOOL")
    }

    // A PostgreSQL or DuckDB `bit` holds digits like `101`, and a MySQL `BIT(8)` reads back as the number it holds.
    // The families are `SQLTypeFamily`'s: its PostgreSQL and MySQL ids are `SqlDialect`'s, and DuckDB is its own.
    private static func bitIsFlag(_ shape: Shape, databaseTypeId: String) -> Bool {
        let dialect = SqlDialect.from(databaseTypeId: databaseTypeId)
        if dialect == .postgres || databaseTypeId == "DuckDB" {
            let spelling = shape.suffix.isEmpty ? "BIT" : "BIT " + shape.suffix.uppercased()
            let bitStrings: Set<String> = dialect == .postgres ? ["BIT", "VARBIT", "BIT VARYING"] : ["BIT", "BITSTRING"]
            if bitStrings.contains(spelling) { return false }
        }
        if dialect == .mysql, let width = shape.params.flatMap({ Int($0) }), width > 1 { return false }
        return true
    }

    // The name as the classifier splits it; nil for an array or a composite, which is neither.
    private struct Shape {
        let base: String
        let params: String?
        let suffix: String

        init?(_ typeName: String) {
            let stripped = Self.strippingAttributes(Self.strippingWrappers(typeName))
            let upper = stripped.uppercased()
            if upper.hasPrefix("ARRAY<") || upper.hasPrefix("STRUCT<") || stripped.hasSuffix("[]") { return nil }
            if let open = stripped.firstIndex(of: "("), let close = stripped.lastIndex(of: ")"), open < close {
                base = String(stripped[..<open])
                params = String(stripped[stripped.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                suffix = String(stripped[stripped.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            } else {
                base = stripped
                params = nil
                suffix = ""
            }
            if base.hasSuffix("[]") { return nil }
        }

        private static func strippingWrappers(_ value: String) -> String {
            for prefix in ["Nullable(", "LowCardinality("] where value.hasPrefix(prefix) && value.hasSuffix(")") {
                return strippingWrappers(String(value.dropFirst(prefix.count).dropLast()))
            }
            return value
        }

        private static func strippingAttributes(_ value: String) -> String {
            var stripped = value
            while let attribute = ["UNSIGNED", "SIGNED", "ZEROFILL"].first(where: { stripped.uppercased().hasSuffix(" \($0)") }) {
                stripped = String(stripped.dropLast(attribute.count)).trimmingCharacters(in: .whitespaces)
            }
            return stripped
        }
    }
}

nonisolated extension ImportTargetValues.ColumnTraits {
    // An engine whose dialect writes `true` and `false` takes the words; one that writes 1 and 0 is sent digits.
    init(typeName: String, databaseTypeId: String, writesNumericBooleans: Bool) {
        self.init(
            holdsBytes: ColumnTypeTraits.holdsBytes(typeName),
            takesNumericBooleans: writesNumericBooleans
                && ColumnTypeTraits.isBooleanFlag(typeName, databaseTypeId: databaseTypeId)
        )
    }
}

nonisolated extension ImportTargetValues {
    // `writesNumericBooleans` is the dialect's `booleanLiteralStyle == .numeric`, which only the host can read.
    init(
        columns: [(name: String, typeName: String, isGenerated: Bool)],
        databaseTypeId: String,
        writesNumericBooleans: Bool,
        binaryText: ImportBinaryText?
    ) {
        self.init(
            columns: columns,
            binaryText: binaryText,
            prefixedHex: { PrefixedHex(reading: $0) },
            traits: { typeName in
                ColumnTraits(
                    typeName: typeName, databaseTypeId: databaseTypeId, writesNumericBooleans: writesNumericBooleans
                )
            }
        )
    }
}
