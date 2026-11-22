//
//  PgpassStatus.swift
//  TablePro
//

import Foundation
import TableProUtilities

enum PgpassStatus {
    case notChecked
    case fileNotFound
    case badPermissions
    case matchFound
    case noMatch

    static func check(host: String, port: Int, database: String, username: String) -> PgpassStatus {
        guard PgpassReader.fileExists() else { return .fileNotFound }
        guard PgpassReader.filePermissionsAreValid() else { return .badPermissions }
        if PgpassReader.resolve(host: host, port: port, database: database, username: username) != nil {
            return .matchFound
        }
        return .noMatch
    }
}
