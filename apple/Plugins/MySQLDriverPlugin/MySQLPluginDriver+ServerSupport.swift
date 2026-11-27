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

    func schemaNamesAreCaseSensitive() async -> Bool {
        let run: MySQLExportCatalog.Run = { [self] in try await self.execute(ownStatement: $0) }
        return await schemaNamesAreCaseSensitive {
            await MySQLExportCatalog.schemaNameCaseSensitivity(run: run)
        }
    }

    // A server that will not answer keeps the plain comparison, for the calls that shared that read only.
    func schemaNamesAreCaseSensitive(reading read: @escaping @Sendable () async -> Bool?) async -> Bool {
        switch schemaNameCase(startingRead: read) {
        case .known(let known):
            return known
        case .reading(let inFlight):
            let answer = await inFlight.value
            settleSchemaNameCaseRead(inFlight, answer: answer)
            return answer ?? false
        }
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
