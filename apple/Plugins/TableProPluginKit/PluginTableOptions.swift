import Foundation

/// A table's default character set and collation, and its AUTO_INCREMENT counter.
public struct PluginTableOptions: Sendable, Equatable {
    public let characterSet: String?
    public let collation: String?
    /// The value the next row takes, or nil when the table has no AUTO_INCREMENT column.
    public let autoIncrement: UInt64?

    public init(characterSet: String? = nil, collation: String? = nil, autoIncrement: UInt64? = nil) {
        self.characterSet = characterSet
        self.collation = collation
        self.autoIncrement = autoIncrement
    }
}

public struct PluginCharacterSet: Sendable, Equatable {
    public let name: String
    public let defaultCollation: String
    /// Every collation of this character set, its default included.
    public let collations: [String]
    public let description: String?

    public init(name: String, defaultCollation: String, collations: [String], description: String? = nil) {
        self.name = name
        self.defaultCollation = defaultCollation
        self.collations = collations
        self.description = description
    }
}

/// What the server offers any table: its character sets and collations, and the storage engines it can create.
public struct PluginTableOptionsCatalog: Sendable, Equatable {
    public let characterSets: [PluginCharacterSet]
    public let engines: [String]
    public let defaultEngine: String?

    public init(characterSets: [PluginCharacterSet], engines: [String] = [], defaultEngine: String? = nil) {
        self.characterSets = characterSets
        self.engines = engines
        self.defaultEngine = defaultEngine
    }
}

/// A change to an existing table's options. A nil field is left as it is.
public struct PluginTableOptionsChange: Sendable, Equatable {
    public let characterSet: String?
    public let collation: String?
    /// Rewrites every text column to `characterSet` and `collation`, which a convert always names, instead of
    /// changing only the default that columns added later take.
    public let convertsColumns: Bool
    public let autoIncrement: UInt64?

    public init(
        characterSet: String? = nil,
        collation: String? = nil,
        convertsColumns: Bool = false,
        autoIncrement: UInt64? = nil
    ) {
        self.characterSet = characterSet
        self.collation = collation
        self.convertsColumns = convertsColumns
        self.autoIncrement = autoIncrement
    }
}

public extension PluginDatabaseDriver {
    func fetchTableOptions(table: String, schema: String?) async throws -> PluginTableOptions? { nil }

    func fetchTableOptionsCatalog() async throws -> PluginTableOptionsCatalog? { nil }

    func fetchDefaultTableOptions(schema: String?) async throws -> PluginTableOptions? { nil }

    func tableOptionsStatement(table: String, schema: String?, change: PluginTableOptionsChange) -> String? {
        nil
    }
}
