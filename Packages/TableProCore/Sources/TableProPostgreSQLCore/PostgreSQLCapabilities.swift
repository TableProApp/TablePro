import Foundation

nonisolated public struct PostgreSQLCapabilities: Sendable, Equatable {
    public let serverVersion: Int32

    public init(serverVersion: Int32) {
        self.serverVersion = serverVersion
    }

    /// libpq answers 0 for a handle it has not connected. A catalog query built for that has to
    /// assume a current server, or it emits the legacy projection on every server that exists.
    public static func assumingModernWhenUnknown(_ serverVersion: Int32) -> PostgreSQLCapabilities {
        PostgreSQLCapabilities(serverVersion: serverVersion <= 0 ? Int32.max : serverVersion)
    }

    public var hasMaterializedViewsCatalog: Bool { serverVersion >= 90_300 }
    public var hasRangeTypes: Bool { serverVersion >= 90_200 }
    public var hasEnumLabelPlacement: Bool { serverVersion >= 90_100 }
    /// ADD VALUE IF NOT EXISTS landed in 9.3. With it an add is idempotent, which is what makes
    /// the driver's one reconnect-and-resend safe for a label that already landed.
    public var hasEnumAddValueIfNotExists: Bool { serverVersion >= 90_300 }
    /// ALTER TYPE ... RENAME VALUE landed in 10; before it a label can only be added.
    public var hasRenameEnumValue: Bool { serverVersion >= 100_000 }
    /// Every range gained a companion multirange in 14, with a name the creator may choose.
    public var hasMultirangeTypes: Bool { serverVersion >= 140_000 }
    public var hasForeignTablesCatalog: Bool { serverVersion >= 90_100 }
    public var hasSequencesCatalog: Bool { serverVersion >= 100_000 }
    public var hasBypassRLS: Bool { serverVersion >= 90_500 }
    public var hasProcedureKind: Bool { serverVersion >= 110_000 }

    public var hasIdentityColumns: Bool { serverVersion >= 100_000 }
    public var hasGeneratedColumns: Bool { serverVersion >= 120_000 }
    /// ALTER TABLE ... ALTER COLUMN ... SET EXPRESSION AS landed in 17; before it, changing a
    /// generation expression means dropping and re-adding the column.
    public var hasSetGeneratedExpression: Bool { serverVersion >= 170_000 }
    /// Virtual generated columns landed in 18; VIRTUAL is a syntax error on every earlier server.
    public var hasVirtualGeneratedColumns: Bool { serverVersion >= 180_000 }
    public var hasDeclarativePartitioning: Bool { serverVersion >= 100_000 }
    /// A foreign key that reaches a partitioned table is stored once per partition from PostgreSQL
    /// 12, and each clone points at the constraint it was cloned from through `conparentid`, a
    /// column that exists from 11.
    public var hasConstraintParent: Bool { serverVersion >= 110_000 }

    public var hasCollationProvider: Bool { serverVersion >= 100_000 }

    public var hasDatabaseICULocale: Bool { serverVersion >= 150_000 }
    public var hasDatabaseLocale: Bool { serverVersion >= 170_000 }
    public var hasModernICUSyntax: Bool { serverVersion >= 160_000 }

    public var hasRenameConstraint: Bool { serverVersion >= 90_200 }
    public var hasSpGistIndexes: Bool { serverVersion >= 90_200 }
    public var hasCreateSchemaIfNotExists: Bool { serverVersion >= 90_300 }
    public var hasBrinIndexes: Bool { serverVersion >= 90_500 }
    public var hasReindexOptions: Bool { serverVersion >= 90_500 }
    /// `INCLUDE` columns and the `indnkeyatts` count that tells them from key columns landed in 11.
    public var hasCoveringIndexes: Bool { serverVersion >= 110_000 }
    public var hasExecuteFunctionTriggerSyntax: Bool { serverVersion >= 110_000 }
    public var hasReindexConcurrently: Bool { serverVersion >= 120_000 }
    public var hasCreateOrReplaceTrigger: Bool { serverVersion >= 140_000 }
    public var hasUnnamedReindexDatabase: Bool { serverVersion >= 160_000 }
}
