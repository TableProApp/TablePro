//
//  MySQLServerVersion.swift
//  MySQLDriverPlugin
//
//  Feature floors for the catalogs the structure editor reads.
//  Compiled into the test target via project.yml.
//

import Foundation

/// One plugin serves MySQL and MariaDB, and they gained these catalogs at different releases.
/// Reading one that does not exist is not a soft failure: the structure load surfaces the error
/// and the whole Structure tab refuses to open, so each read is gated before it runs.
enum MySQLServerVersion {
    /// `(major, minor, patch)` from a version banner such as `8.0.36` or `10.6.16-MariaDB`.
    static func components(from banner: String) -> (major: Int, minor: Int, patch: Int)? {
        let leading = banner.prefix { $0.isNumber || $0 == "." }
        let parts = leading.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        return (major, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }

    static func isAtLeast(_ target: (Int, Int, Int), banner: String?) -> Bool {
        guard let banner, let version = components(from: banner) else { return false }
        if version.major != target.0 { return version.major > target.0 }
        if version.minor != target.1 { return version.minor > target.1 }
        return version.patch >= target.2
    }

    /// MySQL parsed and ignored CHECK before 8.0.16; MariaDB enforces it from 10.2.1.
    /// `INFORMATION_SCHEMA.CHECK_CONSTRAINTS` appears with that support on both.
    static func hasCheckConstraints(banner: String?, isMariaDB: Bool) -> Bool {
        isAtLeast(isMariaDB ? (10, 2, 1) : (8, 0, 16), banner: banner)
    }

    /// `COLUMNS.GENERATION_EXPRESSION` arrived with generated columns: MySQL 5.7.6, MariaDB 10.2.
    /// MariaDB 10.1 has the columns but not the catalog column.
    static func hasGenerationExpression(banner: String?, isMariaDB: Bool) -> Bool {
        isAtLeast(isMariaDB ? (10, 2, 0) : (5, 7, 6), banner: banner)
    }
}
