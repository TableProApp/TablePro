import Foundation

/// A column's type as its declaration spells it, rebuilt from the `ALL_TAB_COLS` row that describes it.
///
/// `DATA_LENGTH` is bytes for every type: twice the declared size of an `NVARCHAR2` in AL16UTF16, four times a
/// `VARCHAR2(n CHAR)` in AL32UTF8. `CHAR_LENGTH` is the declared size of all four character types, `TIMESTAMP` and
/// `INTERVAL` carry their precisions in `DATA_TYPE`, and `FLOAT` keeps its binary precision in `DATA_PRECISION`.
/// Measured on 23ai, every shape below recreates an identical dictionary row through `CREATE TABLE`; a nested table
/// is the one exception, and it needs a storage clause rather than another spelling.
///
/// `DATA_TYPE` is never case-folded: a type created as `"Mixed"` only resolves under that exact name.
public struct OracleColumnTypeSpelling: Sendable, Equatable {
    public let dataType: String
    public let dataLength: Int?
    public let precision: Int?
    public let scale: Int?
    /// `CHAR_LENGTH`.
    public let charLength: Int?
    /// `CHAR_USED`: `B` or `C` for the four character types, nil for every other.
    public let charUsed: String?
    /// `DATA_TYPE_OWNER`, set for object, collection and opaque types and nil for every built-in type.
    public let typeOwner: String?
    /// `DATA_TYPE_MOD`, `REF` for a reference to an object type.
    public let typeModifier: String?
    /// `VECTOR_INFO`, `VECTOR(3,FLOAT32,DENSE)`, on a release that has it.
    public let vectorInfo: String?
    /// The owner of the table the column belongs to: a type in the same schema needs no owner in front of it.
    public let tableOwner: String?

    public init(
        dataType: String,
        dataLength: Int? = nil,
        precision: Int? = nil,
        scale: Int? = nil,
        charLength: Int? = nil,
        charUsed: String? = nil,
        typeOwner: String? = nil,
        typeModifier: String? = nil,
        vectorInfo: String? = nil,
        tableOwner: String? = nil
    ) {
        self.dataType = dataType
        self.dataLength = dataLength
        self.precision = precision
        self.scale = scale
        self.charLength = charLength
        self.charUsed = charUsed
        self.typeOwner = typeOwner
        self.typeModifier = typeModifier
        self.vectorInfo = vectorInfo
        self.tableOwner = tableOwner
    }

    /// The type as `CREATE TABLE` and `ALTER TABLE ... MODIFY` take it back.
    public var declaration: String {
        isUserDefined ? userDefinedDeclaration : builtInDeclaration
    }

    /// The name the app classifies the column by when the declaration would mislead a name-keyed consumer, nil when
    /// the declaration already says it.
    ///
    /// An Oracle `DATE` holds a time of day, so it classifies as `TIMESTAMP(0)`. An owner-qualified, quoted or `REF`
    /// declaration classifies by the bare type name, which is what `XMLTYPE` and `SDO_GEOMETRY` are keyed on.
    public var classificationTypeName: String? {
        if isUserDefined {
            return declaration == dataType ? nil : dataType
        }
        return builtInName == "DATE" ? "TIMESTAMP(0)" : nil
    }

    /// The declared length of a character column, in characters or in bytes as `CHAR_USED` says. Nil for every other
    /// type, including a `VECTOR`, whose `CHAR_LENGTH` is its dimension count.
    public var characterLength: Int? {
        guard !isUserDefined, Self.characterTypes.contains(builtInName) else { return nil }
        return positive(charLength)
    }

    private static let characterTypes: Set<String> = ["VARCHAR2", "CHAR", "NVARCHAR2", "NCHAR"]

    /// The rowid size `UROWID` takes when none is declared.
    private static let defaultURowIDLength = 4_000

    private var isUserDefined: Bool {
        typeOwner != nil || typeModifier == "REF"
    }

    /// Built-in names are keywords, so `number` and `NUMBER` are one type; the declaration still keeps the case reported.
    private var builtInName: String {
        dataType.uppercased()
    }

    private var builtInDeclaration: String {
        switch builtInName {
        case "VARCHAR2", "CHAR":
            return lengthSemanticsDeclaration
        case "NVARCHAR2", "NCHAR":
            return positive(charLength).map { "\(dataType)(\($0))" } ?? dataType
        case "NUMBER":
            return numberDeclaration
        case "FLOAT":
            return precision.map { "\(dataType)(\($0))" } ?? dataType
        case "RAW":
            return positive(dataLength).map { "\(dataType)(\($0))" } ?? dataType
        case "UROWID":
            guard let length = positive(dataLength), length != Self.defaultURowIDLength else { return dataType }
            return "\(dataType)(\(length))"
        case "VECTOR":
            return vectorDeclaration
        default:
            return dataType
        }
    }

    /// Always states `BYTE` or `CHAR`: an unqualified length takes the session's `NLS_LENGTH_SEMANTICS`, so
    /// `VARCHAR2(50)` replayed in a `CHAR` session makes a 50-character column out of a 50-byte one (measured).
    private var lengthSemanticsDeclaration: String {
        let usesCharacters = charUsed == "C"
        let length = positive(charLength) ?? (usesCharacters ? nil : positive(dataLength))
        guard let length else { return dataType }
        return "\(dataType)(\(length) \(usesCharacters ? "CHAR" : "BYTE"))"
    }

    /// `NUMBER(*,s)` reports no precision and keeps its scale, and `INTEGER` is stored that way as `NUMBER(*,0)`. A
    /// negative scale rounds left of the point and is kept.
    private var numberDeclaration: String {
        switch (precision, scale) {
        case (nil, nil):
            return dataType
        case (nil, let scale?):
            return "\(dataType)(*,\(scale))"
        case (let precision?, nil), (let precision?, 0?):
            return "\(dataType)(\(precision))"
        case (let precision?, let scale?):
            return "\(dataType)(\(precision),\(scale))"
        }
    }

    /// Without `VECTOR_INFO` the dimension count still comes from `CHAR_LENGTH`, which is 0 for a flexible one, and the
    /// element format stays open.
    private var vectorDeclaration: String {
        if let vectorInfo, let declared = Self.vectorDeclaration(typeName: dataType, info: vectorInfo) {
            return declared
        }
        guard let dimensions = positive(charLength) else { return dataType }
        return "\(dataType)(\(dimensions), *)"
    }

    /// `VECTOR_INFO` spells every part, `VECTOR(*,*,DENSE)` for a plain `VECTOR`. `DENSE` is the default storage and a
    /// trailing `*` the default dimension or format, so both go from the end; `SPARSE` keeps the parts before it.
    static func vectorDeclaration(typeName: String, info: String) -> String? {
        guard let open = info.firstIndex(of: "("), let close = info.lastIndex(of: ")"), open < close else { return nil }
        var parts = info[info.index(after: open)..<close]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.contains(where: \.isEmpty) else { return nil }
        if parts.last?.uppercased() == "DENSE" {
            parts.removeLast()
        }
        while parts.last == "*" {
            parts.removeLast()
        }
        guard !parts.isEmpty else { return typeName }
        return "\(typeName)(\(parts.joined(separator: ", ")))"
    }

    /// Qualified with its owner when that is another schema, since an unqualified name resolves in the session's
    /// schema. `PUBLIC` owns the synonym-reached types such as `XMLTYPE`, which need no owner.
    private var userDefinedDeclaration: String {
        let name: String
        if let typeOwner, typeOwner != "PUBLIC", typeOwner != tableOwner {
            name = "\(OracleSchemaQueries.quoteIdentifier(typeOwner)).\(OracleSchemaQueries.quoteIdentifier(dataType))"
        } else {
            name = Self.isOrdinaryIdentifier(dataType) ? dataType : OracleSchemaQueries.quoteIdentifier(dataType)
        }
        return typeModifier == "REF" ? "REF \(name)" : name
    }

    /// A name Oracle reads back as itself without quotes: an uppercase letter, then uppercase letters, digits, `_`,
    /// `$` and `#`.
    static func isOrdinaryIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("A"..."Z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "$" || scalar == "#"
        }
    }

    private func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
