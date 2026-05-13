//
//  PostgreSQLCapabilities.swift
//  PostgreSQLDriverPlugin
//

import Foundation

struct PostgreSQLCapabilities: Sendable, Equatable {
    let serverVersion: Int32

    static let unknown = PostgreSQLCapabilities(serverVersion: 0)

    var hasMaterializedViewsCatalog: Bool { serverVersion >= 90_300 }
    var hasForeignTablesCatalog: Bool { serverVersion >= 90_100 }
    var hasSequencesCatalog: Bool { serverVersion >= 90_500 }

    var hasIdentityColumns: Bool { serverVersion >= 100_000 }
    var hasGeneratedColumns: Bool { serverVersion >= 120_000 }

    var hasArrayPosition: Bool { serverVersion >= 90_500 }
    var hasOrderedAggregates: Bool { serverVersion >= 90_000 }

    var hasCollationProvider: Bool { serverVersion >= 100_000 }

    var hasDatabaseICULocale: Bool { serverVersion >= 150_000 }
    var hasDatabaseLocale: Bool { serverVersion >= 170_000 }
}
