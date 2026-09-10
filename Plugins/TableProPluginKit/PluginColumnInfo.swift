import Foundation

public enum IdentityKind: String, Codable, Sendable, CaseIterable {
    case always = "ALWAYS"
    case byDefault = "BY DEFAULT"
}

/// How a generated column's value is materialised.
///
/// Engines disagree on the default and on which kinds exist at all: PostgreSQL 17 and earlier
/// accept only `stored` and reject the `VIRTUAL` keyword outright, PostgreSQL 18 made `virtual`
/// the default, and MySQL and MariaDB default to `virtual`. A driver therefore always spells the
/// keyword rather than relying on the server's default.
public enum GenerationKind: String, Codable, Sendable, CaseIterable {
    case stored = "STORED"
    case virtual = "VIRTUAL"
}

public struct PluginColumnInfo: Codable, Sendable {
    public let name: String
    public let dataType: String
    public let isNullable: Bool
    public let isPrimaryKey: Bool
    /// The exact SQL that follows the `DEFAULT` keyword, or nil for no `DEFAULT` clause at all.
    ///
    /// A literal carries its own quotes (`'abc'`, `''`), an expression is written the way the engine
    /// spells it (`now()`, `gen_random_uuid()`, `(datetime('now'))`), and `NULL` means `DEFAULT NULL`
    /// rather than the absence of a default. A driver emits this verbatim and never re-quotes it.
    ///
    /// It used to be untyped text, which left every writer guessing literal from expression against a
    /// hand-copied allowlist. Measured, that turned `gen_random_uuid()` into an eleven-character
    /// string and `nextval('t_id_seq'::regclass)` into a value PostgreSQL rejects. Adding required
    /// syntax the engine's own grammar demands is still the driver's job: MySQL takes a `TEXT`
    /// default only in parentheses, whatever the value is.
    public let defaultValue: String?
    public let extra: String?
    public let charset: String?
    public let collation: String?
    public let comment: String?
    public let identityKind: IdentityKind?
    public let isGenerated: Bool
    public let allowedValues: [String]?
    public let generationExpression: String?
    public let generationKind: GenerationKind?

    public var isIdentity: Bool { identityKind != nil }

    /// The signature published before generated-column detail existed. Kept byte-identical and
    /// disfavoured so plugins built against an older PluginKit keep resolving their own mangled
    /// symbol; adding a parameter here instead would break every one of them, as `columnMeta:`
    /// did in 0.49.0.
    @_disfavoredOverload
    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        defaultValue: String? = nil,
        extra: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        comment: String? = nil,
        identityKind: IdentityKind? = nil,
        isGenerated: Bool = false,
        allowedValues: [String]? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
        self.extra = extra
        self.charset = charset
        self.collation = collation
        self.comment = comment
        self.identityKind = identityKind
        self.isGenerated = isGenerated
        self.allowedValues = allowedValues
        self.generationExpression = nil
        self.generationKind = nil
    }

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        defaultValue: String? = nil,
        extra: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        comment: String? = nil,
        identityKind: IdentityKind? = nil,
        isGenerated: Bool = false,
        allowedValues: [String]? = nil,
        generationExpression: String?,
        generationKind: GenerationKind?
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
        self.extra = extra
        self.charset = charset
        self.collation = collation
        self.comment = comment
        self.identityKind = identityKind
        self.isGenerated = isGenerated
        self.allowedValues = allowedValues
        self.generationExpression = generationExpression
        self.generationKind = generationKind
    }
}
