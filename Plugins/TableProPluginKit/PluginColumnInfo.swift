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
    /// The type as the server declares it, which is what every display of the column shows.
    ///
    /// It carries the modifier and names the type the way the server writes it relative to the
    /// table's own schema: `character varying(50)`, `numeric(10,2)`, an enum by its name, a type
    /// from another schema qualified. A driver whose catalog reports a classified name instead sets
    /// `classificationTypeName`, because this one is no longer the name the app classifies.
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
    /// The type as this server writes it after the column name in `CREATE TABLE`, or nil where the
    /// driver has nothing more exact than `dataType`.
    ///
    /// `dataType` is the spelling the app classifies, and it cannot also be this one. PostgreSQL
    /// reports an enum column as `ENUM`, which is what gives the column its value picker, and a
    /// PostGIS column as `geometry`, which names neither the schema the type lives in nor its SRID.
    /// Replayed into a `CREATE TABLE` on a connection whose `search_path` is another schema, both
    /// failed with "type does not exist". This spelling is schema-qualified wherever the name would
    /// not resolve on its own, carries the type modifier, and quotes its identifiers, so a DDL writer
    /// emits it verbatim.
    public let ddlSpelling: String?
    /// `defaultValue` as a `CREATE TABLE` on another schema has to write it, or nil to write
    /// `defaultValue`.
    ///
    /// A default names types and functions the same way a column type does, so `'new'::status` and
    /// `st_geomfromtext(...)` failed under a target `search_path` just as `geometry` did. A sequence
    /// in the table's own schema is the one name left relative: a copy recreates that sequence beside
    /// the table, and `nextval('orders_id_seq'::regclass)` has to bind to the new one rather than to
    /// the source's. A sequence in any other schema stays qualified, because nothing recreates it.
    public let ddlDefault: String?
    /// `generationExpression` as a `CREATE TABLE` on another schema has to write it, or nil to write
    /// `generationExpression`.
    public let ddlGenerationExpression: String?
    /// What follows `COLLATE` in a `CREATE TABLE`, or nil where the column keeps its type's own
    /// collation.
    ///
    /// `collation` is the name to show, and it cannot also be this one. PostgreSQL reports `C` for a
    /// column declared `COLLATE "C"` and for one that only inherits `C` from its type, and it reports
    /// no schema: a bare `COLLATE C` is refused, and `"Case Insens"` names nothing outside its own
    /// schema. This spelling is qualified and quoted, and set only when the column declares a
    /// collation its type does not, so a DDL writer emits it verbatim.
    public let ddlCollation: String?
    /// The name the app classifies the column by, or nil to classify `dataType`.
    ///
    /// A declared spelling says what the column holds only where the app knows the type. PostgreSQL
    /// spells an enum column by the enum's name, a domain column by the domain's name and a PostGIS
    /// column `public.geometry(Point,4326)`, and none of those names a kind: classified, they all
    /// read as text, which takes the value picker off an enum and the spatial rendering off a
    /// geometry. This is the classified name for exactly those columns, `ENUM`, `INTEGER`,
    /// `geometry`, and nil wherever the declared spelling classifies the same.
    public let classificationTypeName: String?

    public var isIdentity: Bool { identityKind != nil }

    /// What a classifier reads: the hint where the driver set one, the declared type otherwise.
    public var typeNameForClassification: String { classificationTypeName ?? dataType }

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
        self.ddlSpelling = nil
        self.ddlDefault = nil
        self.ddlGenerationExpression = nil
        self.ddlCollation = nil
        self.classificationTypeName = nil
    }

    /// The signature published before the DDL spellings existed, kept byte-identical and disfavoured
    /// for the same reason as the one above.
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
        self.ddlSpelling = nil
        self.ddlDefault = nil
        self.ddlGenerationExpression = nil
        self.ddlCollation = nil
        self.classificationTypeName = nil
    }

    /// The signature published before `ddlCollation` existed, kept byte-identical and disfavoured for
    /// the same reason as the ones above.
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
        allowedValues: [String]? = nil,
        generationExpression: String?,
        generationKind: GenerationKind?,
        ddlSpelling: String?,
        ddlDefault: String?,
        ddlGenerationExpression: String?
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
        self.ddlSpelling = ddlSpelling
        self.ddlDefault = ddlDefault
        self.ddlGenerationExpression = ddlGenerationExpression
        self.ddlCollation = nil
        self.classificationTypeName = nil
    }

    /// The signature published before `classificationTypeName` existed, kept byte-identical and
    /// disfavoured for the same reason as the ones above.
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
        allowedValues: [String]? = nil,
        generationExpression: String?,
        generationKind: GenerationKind?,
        ddlSpelling: String?,
        ddlDefault: String?,
        ddlGenerationExpression: String?,
        ddlCollation: String?
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
        self.ddlSpelling = ddlSpelling
        self.ddlDefault = ddlDefault
        self.ddlGenerationExpression = ddlGenerationExpression
        self.ddlCollation = ddlCollation
        self.classificationTypeName = nil
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
        generationKind: GenerationKind?,
        ddlSpelling: String?,
        ddlDefault: String?,
        ddlGenerationExpression: String?,
        ddlCollation: String?,
        classificationTypeName: String?
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
        self.ddlSpelling = ddlSpelling
        self.ddlDefault = ddlDefault
        self.ddlGenerationExpression = ddlGenerationExpression
        self.ddlCollation = ddlCollation
        self.classificationTypeName = classificationTypeName
    }
}
