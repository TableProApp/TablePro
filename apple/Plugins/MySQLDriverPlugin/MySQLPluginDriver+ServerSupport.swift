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

    // A server that will not answer keeps the plain comparison, for this call only.
    func schemaNamesAreCaseSensitive() async -> Bool {
        if let known = cachedSchemaNamesAreCaseSensitive { return known }
        let run: MySQLExportCatalog.Run = { [self] in try await self.execute(ownStatement: $0) }
        guard let sensitive = await MySQLExportCatalog.schemaNameCaseSensitivity(run: run) else { return false }
        cachedSchemaNamesAreCaseSensitive = sensitive
        return sensitive
    }

    // Built per call, so each read sees the banner, flavor and database of the session it runs on.
    var exportCatalog: MySQLExportCatalog {
        let identity = serverIdentity
        return MySQLExportCatalog(
            banner: identity.banner,
            flavor: identity.flavor,
            activeDatabase: activeDatabaseName,
            quote: { [self] in self.quoteIdentifier($0) },
            run: { [self] in try await self.execute(ownStatement: $0) },
            schemaNamesAreCaseSensitive: { [self] in await self.schemaNamesAreCaseSensitive() },
            settlesBlindness: { MySQLPluginDriver.settlesBlindness($0) }
        )
    }
}
