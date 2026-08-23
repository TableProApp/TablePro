//
//  SchemaMenuModel.swift
//  TablePro
//

import Foundation

/// How the schema list is split for a menu: the schemas a user works in, and the ones the server
/// owns. Pure, so the grouping is testable without a menu, a window or a connection.
internal enum SchemaMenuModel {
    internal struct Sections: Equatable {
        internal let user: [String]
        internal let system: [String]

        internal var isEmpty: Bool { user.isEmpty && system.isEmpty }
    }

    /// Server order is kept rather than sorted, because that order is meaningful on some engines
    /// (a search path puts the schema you will actually hit first).
    internal static func sections(all: [String], system: Set<String>) -> Sections {
        Sections(
            user: all.filter { !system.contains($0) },
            system: all.filter { system.contains($0) }
        )
    }
}
