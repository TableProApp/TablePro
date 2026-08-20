//
//  PostgreSQLSystemDatabases.swift
//  PostgreSQLDriverPlugin
//

import Foundation

enum PostgreSQLSystemDatabases {
    static let postgreSQL: [String] = []
    static let redshift: [String] = ["padb_harvest"]
    static let cockroachDB: [String] = ["system"]
}
