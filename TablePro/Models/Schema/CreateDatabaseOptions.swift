//
//  CreateDatabaseOptions.swift
//  TablePro
//
//  Database-type-specific options for CREATE DATABASE dialog.
//

import Foundation

struct CreateDatabaseOptions {
    struct Config {
        let charsetLabel: String
        let collationLabel: String
        let defaultCharset: String
        let defaultCollation: String
        let charsets: [String]
        let collations: [String: [String]]
        let showOptions: Bool
    }

    static func config(for type: DatabaseType) -> Config {
        if type == .mysql || type == .mariadb {
            return Config(
                charsetLabel: "Character Set",
                collationLabel: "Collation",
                defaultCharset: "utf8mb4",
                defaultCollation: "utf8mb4_unicode_ci",
                charsets: CreateTableOptions.charsets,
                collations: CreateTableOptions.collations,
                showOptions: true
            )
        } else if type == .postgresql || type == .redshift {
            return Config(
                charsetLabel: "Encoding",
                collationLabel: "LC_COLLATE",
                defaultCharset: "UTF8",
                defaultCollation: "en_US.UTF-8",
                charsets: postgresqlEncodings,
                collations: postgresqlLocales,
                showOptions: true
            )
        } else {
            return Config(
                charsetLabel: "",
                collationLabel: "",
                defaultCharset: "",
                defaultCollation: "",
                charsets: [],
                collations: [:],
                showOptions: false
            )
        }
    }

    private static let postgresqlEncodings = [
        "UTF8", "LATIN1", "SQL_ASCII", "WIN1252", "EUC_JP",
        "EUC_KR", "ISO_8859_5", "KOI8R", "SJIS", "BIG5", "GBK"
    ]

    // PostgreSQL LC_COLLATE is OS-locale based, not encoding-dependent
    private static let localeOptions = ["en_US.UTF-8", "C", "POSIX", "C.UTF-8"]

    private static let postgresqlLocales: [String: [String]] = {
        var result: [String: [String]] = [:]
        for enc in postgresqlEncodings {
            result[enc] = localeOptions
        }
        return result
    }()
}
