//
//  PostgreSQLCapabilities.swift
//  PostgreSQLDriverPlugin
//

import Foundation

struct PostgreSQLCapabilities: Sendable, Equatable {
    let serverVersion: Int32

    static let unknown = PostgreSQLCapabilities(serverVersion: 0)

    /// libpq answers 0 for a handle it has not connected. A catalog query built for that has to
    /// assume a current server, or it emits the legacy projection on every server that exists.
    static func assumingModernWhenUnknown(_ serverVersion: Int32) -> PostgreSQLCapabilities {
        PostgreSQLCapabilities(serverVersion: serverVersion <= 0 ? Int32.max : serverVersion)
    }

    var hasMaterializedViewsCatalog: Bool { serverVersion >= 90_300 }
    var hasRangeTypes: Bool { serverVersion >= 90_200 }
    var hasJsonBuildObject: Bool { serverVersion >= 90_400 }
    var hasEnumLabelPlacement: Bool { serverVersion >= 90_100 }
    /// ADD VALUE IF NOT EXISTS landed in 9.3. With it an add is idempotent, which is what makes
    /// the driver's one reconnect-and-resend safe for a label that already landed.
    var hasEnumAddValueIfNotExists: Bool { serverVersion >= 90_300 }
    /// ALTER TYPE ... RENAME VALUE landed in 10; before it a label can only be added.
    var hasRenameEnumValue: Bool { serverVersion >= 100_000 }
    /// Every range gained a companion multirange in 14, with a name the creator may choose.
    var hasMultirangeTypes: Bool { serverVersion >= 140_000 }
    var hasForeignTablesCatalog: Bool { serverVersion >= 90_100 }
    var hasSequencesCatalog: Bool { serverVersion >= 90_500 }
    var hasBypassRLS: Bool { serverVersion >= 90_500 }

    var hasIdentityColumns: Bool { serverVersion >= 100_000 }
    var hasGeneratedColumns: Bool { serverVersion >= 120_000 }
    /// ALTER TABLE ... ALTER COLUMN ... SET EXPRESSION AS landed in 17; before it, changing a
    /// generation expression means dropping and re-adding the column.
    var hasSetGeneratedExpression: Bool { serverVersion >= 170_000 }
    /// Virtual generated columns landed in 18; VIRTUAL is a syntax error on every earlier server.
    var hasVirtualGeneratedColumns: Bool { serverVersion >= 180_000 }
    var hasDeclarativePartitioning: Bool { serverVersion >= 100_000 }

    var hasArrayPosition: Bool { serverVersion >= 90_500 }
    var hasOrderedAggregates: Bool { serverVersion >= 90_000 }

    var hasCollationProvider: Bool { serverVersion >= 100_000 }

    var hasDatabaseICULocale: Bool { serverVersion >= 150_000 }
    var hasDatabaseLocale: Bool { serverVersion >= 170_000 }
    var hasModernICUSyntax: Bool { serverVersion >= 160_000 }
}
