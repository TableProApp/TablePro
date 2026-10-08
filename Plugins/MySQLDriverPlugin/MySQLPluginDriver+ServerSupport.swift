//
//  MySQLPluginDriver+ServerSupport.swift
//  MySQLDriverPlugin
//
//  What the connected server refuses, as opposed to what the engine can do at its newest.
//

import Foundation
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
}
