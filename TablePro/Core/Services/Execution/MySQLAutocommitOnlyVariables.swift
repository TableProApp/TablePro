//
//  MySQLAutocommitOnlyVariables.swift
//  TablePro
//

import Foundation

internal enum MySQLVariableScope: String, Hashable, Sendable, CaseIterable {
    case session
    case global
}

/// The system variables MySQL and MariaDB refuse to set while a transaction is open, keyed by the
/// scope that refuses. `SET SESSION binlog_format` answers `ERROR 1679` and `SET GLOBAL
/// binlog_format` is allowed, so the scope is part of the key rather than a flag beside it.
///
/// `PERSIST` writes the running global value as well as the file, so it resolves to `.global`.
/// `PERSIST_ONLY` writes only the file and is allowed inside a transaction, so it matches nothing.
///
/// This is a hand-written list that has to agree with two servers and that nothing at runtime
/// checks, which is the shape that let seven MySQL 8.4 variables go missing.
/// `scripts/check-mysql-autocommit-only-variables.sh` tries every variable the server has against a
/// live server and reports both directions, and it reads this table out of this file, so the
/// literal below stays one entry per line.
internal enum MySQLAutocommitOnlyVariables {
    internal static func refuses(_ name: String, scope: MySQLVariableScope) -> Bool {
        curated[name]?.contains(scope) ?? false
    }

    internal static let curated: [String: Set<MySQLVariableScope>] = [
        "BINLOG_CHECKSUM": [.global],
        "BINLOG_DIRECT_NON_TRANSACTIONAL_UPDATES": [.session],
        "BINLOG_FORMAT": [.session],
        "BINLOG_ROW_VALUE_OPTIONS": [.session, .global],
        "BINLOG_TRANSACTION_COMPRESSION": [.session],
        "BINLOG_TRANSACTION_COMPRESSION_LEVEL_ZSTD": [.session],
        "ENFORCE_GTID_CONSISTENCY": [.global],
        "EXPLICIT_DEFAULTS_FOR_TIMESTAMP": [.session],
        "GROUP_REPLICATION_CONSISTENCY": [.session],
        "GTID_BINLOG_STATE": [.global],
        "GTID_DOMAIN_ID": [.session],
        "GTID_MODE": [.global],
        "GTID_NEXT": [.session],
        "GTID_PURGED": [.global],
        "GTID_SEQ_NO": [.session],
        "GTID_SLAVE_POS": [.global],
        "PSEUDO_REPLICA_MODE": [.session],
        "PSEUDO_SLAVE_MODE": [.session],
        "READ_ONLY": [.global],
        "SESSION_TRACK_GTIDS": [.session],
        "SKIP_REPLICATION": [.session],
        "SQL_LOG_BIN": [.session],
        "WSREP_ON": [.session],
        "XA_DETACH_ON_PREPARE": [.session]
    ]
}
