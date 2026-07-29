//
//  ScannedConnectionURLBuilder.swift
//  TablePro
//

import Foundation

enum ScannedConnectionURLBuilder {
    private static let schemeAliases: [String: String] = [
        "pgsql": "postgresql",
        "psql": "postgresql",
        "postgis": "postgresql",
        "timescale": "postgresql",
        "timescalegis": "postgresql",
        "mysql2": "mysql",
        "trilogy": "mysql",
        "mysql-connector": "mysql",
        "mysqlgis": "mysql",
        "sqlite3": "sqlite",
        "spatialite": "sqlite",
        "sqlsrv": "mssql",
        "mssqlms": "mssql",
        "cockroach": "cockroachdb",
        "oraclegis": "oracle",
    ]

    private static let rejectedSchemes: Set<String> = ["prisma", "prisma+postgres"]

    static func parse(_ rawValue: String) -> ParsedConnectionURL? {
        guard let prepared = prepare(rawValue) else {
            return nil
        }
        guard case .success(let parsed) = ConnectionURLParser.parse(prepared) else {
            return nil
        }
        return parsed
    }

    static func prepare(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        value = strippingQuotes(value)
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("jdbc:"),
           !lowercased.hasPrefix("jdbc:sqlserver:"),
           !lowercased.hasPrefix("jdbc:oracle:") {
            value = String(value.dropFirst("jdbc:".count))
        }
        guard let schemeRange = value.range(of: "://") else {
            return nil
        }
        let scheme = value[value.startIndex..<schemeRange.lowerBound].lowercased()
        guard !rejectedSchemes.contains(scheme) else {
            return nil
        }
        if let canonical = schemeAliases[scheme] {
            value = canonical + String(value[schemeRange.lowerBound...])
        }
        return ScannedURLNormalizer.normalize(value)
    }

    static func candidate(
        fromURL rawValue: String,
        key: String,
        relativePath: String,
        kind: ProjectConfigFileKind,
        tier: ScannedConnectionTier,
        warnings: [String] = []
    ) -> ScannedConnectionCandidate? {
        guard let parsed = parse(rawValue) else {
            return nil
        }
        return ScannedConnectionCandidate(
            parsedURL: parsed,
            sourceRelativePath: relativePath,
            sourceKey: key,
            kind: kind,
            tier: tier,
            warnings: warnings
        )
    }

    private static func strippingQuotes(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }
        let first = value.first
        let last = value.last
        guard first == last, first == "\"" || first == "'" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}
