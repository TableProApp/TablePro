//
//  StructureTabAvailability.swift
//  TablePro
//

import Foundation

/// Which tabs the Structure editor offers, from what the engine can do and what the connected
/// server answers for.
///
/// Both halves matter. `supportsCheckConstraints` is the engine at its newest release; the server
/// in front of the user may be older than the release that gained them, and MySQL before 8.0.16
/// and MariaDB before 10.2.1 answer `Query OK` to a `CHECK` clause and throw it away. Offering the
/// tab there is offering an edit that reports success and changes nothing.
enum StructureTabAvailability {
    static func tabs(for type: DatabaseType, serverSupport: StructureServerSupport) -> [StructureTab] {
        StructureTab.allCases.filter { tab in
            engineOffers(tab, on: type) && serverSupport.offers(tab)
        }
    }

    private static func engineOffers(_ tab: StructureTab, on type: DatabaseType) -> Bool {
        switch tab {
        case .foreignKeys:
            return type.supportsForeignKeys
        case .parts:
            return type == .clickhouse
        case .triggers:
            return type.supportsTriggers
        case .checkConstraints:
            return type.supportsCheckConstraints
        case .columns, .indexes, .ddl:
            return true
        }
    }
}
