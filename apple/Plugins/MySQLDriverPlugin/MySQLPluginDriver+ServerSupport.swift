//
//  MySQLPluginDriver+ServerSupport.swift
//  MySQLDriverPlugin
//
//  What the connected server refuses, as opposed to what the engine can do at its newest.
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

internal extension MySQLPluginDriver {
    var checkConstraintRefusal: String? {
        let identity = serverIdentity
        return MySQLCheckConstraints.refusal(banner: identity.banner, flavor: identity.flavor)
    }

    /// One of the `MySQLServerVersion` floors, asked of the banner and flavor `connect()` wrote together.
    func holdsForServer(_ floor: (String?, MySQLServerFlavor) -> Bool) -> Bool {
        let identity = serverIdentity
        return floor(identity.banner, identity.flavor)
    }

    var serverHasInformationSchema: Bool {
        holdsForServer(MySQLServerVersion.hasInformationSchema(banner:flavor:))
    }

    var serverAppendsInnoDBStatus: Bool {
        holdsForServer(MySQLServerVersion.appendsInnoDBStatusToComment(banner:flavor:))
    }

    /// Whether a catalog read has to compare the schema name byte for byte: true under
    /// `lower_case_table_names = 0`. A server that will not answer keeps the plain comparison, for
    /// this call only.
    func schemaNamesAreCaseSensitive() async -> Bool {
        if let known = cachedSchemaNamesAreCaseSensitive { return known }
        guard let result = try? await execute(ownStatement: MySQLObjectQueries.lowerCaseTableNames),
              let setting = result.rows.first?[safe: 0]?.asText.flatMap({ Int($0) })
        else { return false }
        let sensitive = setting == 0
        cachedSchemaNamesAreCaseSensitive = sensitive
        return sensitive
    }
}
