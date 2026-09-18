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
}
