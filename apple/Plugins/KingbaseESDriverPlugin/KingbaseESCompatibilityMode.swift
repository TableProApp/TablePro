import Foundation
import TableProPluginKit

/// The SQL a KingbaseES server speaks, fixed when its cluster is initialized.
enum KingbaseESCompatibilityMode: Equatable, Sendable {
    case postgreSQL
    case oracle

    // The two-argument form answers NULL where the parameter does not exist, which reads as PostgreSQL mode.
    static let probeQuery = "SELECT current_setting('database_mode', true)"

    static let lexicalFeaturesItDecides: SQLLexicalFeatures = [
        .alternativeQuoting, .plsqlBlocks, .slashLineTerminators, .dollarAndHashInIdentifiers,
    ]

    init(setting: String?) throws {
        switch setting?.lowercased() {
        case nil, "pg":
            self = .postgreSQL
        case "oracle":
            self = .oracle
        case let other?:
            throw LibPQPluginError(
                message: String(
                    format: String(localized: "KingbaseES in %@ mode is not supported. Connect to a server in PostgreSQL or Oracle mode."),
                    other
                ),
                sqlState: nil,
                detail: nil
            )
        }
    }

    var lexicalFeatures: SQLLexicalFeatures {
        self == .oracle ? Self.lexicalFeaturesItDecides : []
    }
}
