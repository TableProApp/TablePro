//
//  SQLExportSessionDeclaration.swift
//  SQLExportPlugin
//

import Foundation
import TableProPluginKit

internal struct SQLExportSessionDeclaration: Equatable {
    static let empty = SQLExportSessionDeclaration(prologue: "", epilogue: "")

    let prologue: String
    let epilogue: String

    private static let typesAcceptingSetClientEncoding: Set<String> = [
        "PostgreSQL", "Greenplum", "AlloyDB", "Citus", "CockroachDB", "PGlite", "KingbaseES"
    ]

    /// `readTimeZone` is the zone the rows were read in, from the export's read scope. Only a MySQL dump declares
    /// it, and only when given: declaring a zone the rows were not read in shifts every TIMESTAMP on reload.
    ///
    /// `readsWithANSIQuotes` means the server spelled the DDL under `ANSI_QUOTES`, with `"` around identifiers, so
    /// the dump's mode keeps it or the CREATE does not parse on reload. What the dump spells itself uses backticks and
    /// single quotes, which read the same either way.
    static func forDatabaseType(
        _ databaseTypeId: String,
        readTimeZone: String? = nil,
        readsWithANSIQuotes: Bool = false
    ) -> SQLExportSessionDeclaration {
        switch SqlDialect.from(databaseTypeId: databaseTypeId) {
        case .mysql:
            return mysql(
                readTimeZone: readTimeZone.flatMap(plainTimeZone),
                sqlMode: readsWithANSIQuotes ? "NO_AUTO_VALUE_ON_ZERO,ANSI_QUOTES" : "NO_AUTO_VALUE_ON_ZERO")
        case .postgres where typesAcceptingSetClientEncoding.contains(databaseTypeId):
            return postgres
        default:
            return .empty
        }
    }

    /// mysqldump's own lines. The whole `SQL_MODE` is replaced rather than edited, so the target's strict mode,
    /// `NO_ZERO_DATE` and `NO_BACKSLASH_ESCAPES` cannot reject or reread a literal, and `NO_AUTO_VALUE_ON_ZERO`
    /// keeps an AUTO_INCREMENT value of 0.
    private static func mysql(readTimeZone: String?, sqlMode: String) -> SQLExportSessionDeclaration {
        var prologue = [
            "/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;",
            "/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;",
            "/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;",
            "/*!40101 SET NAMES utf8 */;",
            "/*!50503 SET NAMES utf8mb4 */;",
        ]
        var epilogue: [String] = []
        if let readTimeZone {
            prologue.append("/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;")
            prologue.append("/*!40103 SET TIME_ZONE='\(readTimeZone)' */;")
            epilogue.append("/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;")
        }
        prologue.append("/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;")
        prologue.append("/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='\(sqlMode)' */;")
        epilogue.append(contentsOf: [
            "/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;",
            "/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;",
            "/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;",
            "/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;",
            "/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;",
        ])
        return SQLExportSessionDeclaration(
            prologue: prologue.joined(separator: "\n") + "\n\n",
            epilogue: "\n" + epilogue.joined(separator: "\n") + "\n"
        )
    }

    /// The zone is written inside a `/*! */` comment and a string literal, so anything but a plain spelling such as
    /// `+00:00`, `SYSTEM` or `Europe/Paris` is dropped: a `*/` ends the comment, a quote ends the literal, and a
    /// backslash reads differently under `NO_BACKSLASH_ESCAPES`. 64 is the width of `mysql.time_zone_name.Name`.
    private static func plainTimeZone(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 64 else { return nil }
        let isPlain = value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/_+-:".contains($0)) }
        return isPlain ? value : nil
    }

    private static let postgres = SQLExportSessionDeclaration(
        prologue: """
        SET client_encoding = 'UTF8';


        """,
        epilogue: ""
    )
}
