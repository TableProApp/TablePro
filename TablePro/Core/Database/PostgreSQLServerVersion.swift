//
//  PostgreSQLServerVersion.swift
//  TablePro
//

import Foundation

enum PostgreSQLJSONColumnType: String, Sendable {
    case jsonb = "JSONB"
    case json = "JSON"
    case text = "TEXT"
}

struct PostgreSQLServerVersion: Comparable, Hashable, Sendable {
    typealias JSONColumnType = PostgreSQLJSONColumnType

    static let stateColumns = PostgreSQLServerVersion(number: 90_200)
    static let jsonType = PostgreSQLServerVersion(number: 90_200)
    static let jsonbType = PostgreSQLServerVersion(number: 90_400)
    static let backendTypeColumn = PostgreSQLServerVersion(number: 100_000)

    let number: Int

    init(number: Int) {
        self.number = number
    }

    init?(_ text: String?) {
        guard let text, let components = Self.leadingVersionComponents(in: text) else { return nil }
        let major = components[0]
        let second = components.count > 1 ? components[1] : 0
        let third = components.count > 2 ? components[2] : 0
        self.number = major >= 10
            ? major * 10_000 + second
            : major * 10_000 + second * 100 + third
    }

    static func release(_ majorReleaseNumber: Int) -> PostgreSQLServerVersion {
        PostgreSQLServerVersion(number: majorReleaseNumber * 100)
    }

    var majorReleaseNumber: Int {
        number / 100
    }

    var majorReleaseName: String {
        let major = number / 10_000
        guard major < 10 else { return String(major) }
        return "\(major).\((number / 100) % 100)"
    }

    var fullName: String {
        let major = number / 10_000
        guard major < 10 else { return "\(major).\(number % 10_000)" }
        return "\(major).\((number / 100) % 100).\(number % 100)"
    }

    /// The richest JSON column type a target holds.
    ///
    /// Only `.postgresql` is read from the reported version. Redshift reports 8.0.2 and CockroachDB
    /// reports 13.0.0, and neither number describes the JSON support that engine actually has.
    static func jsonColumnType(for databaseType: DatabaseType, serverVersion: String?) -> JSONColumnType {
        guard databaseType == .postgresql, let version = PostgreSQLServerVersion(serverVersion) else {
            return .jsonb
        }
        if version >= .jsonbType { return .jsonb }
        return version >= .jsonType ? .json : .text
    }

    static func < (lhs: PostgreSQLServerVersion, rhs: PostgreSQLServerVersion) -> Bool {
        lhs.number < rhs.number
    }

    private static func leadingVersionComponents(in text: String) -> [Int]? {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        for token in tokens {
            guard let first = token.first, first.isASCII, first.isNumber else { continue }
            let numeric = token.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
            let components = numeric.split(separator: ".").compactMap { Int($0) }
            guard let major = components.first, major > 0 else { continue }
            return components
        }
        return nil
    }
}
