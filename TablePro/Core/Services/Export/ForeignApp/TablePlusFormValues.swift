//
//  TablePlusFormValues.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum TablePlusPasswordMode: Int {
    case storeInKeychain = 0
    case askEveryTime = 1
    case noPassword = 2
    case commandLine = 3

    static func resolve(_ raw: Any?) -> TablePlusPasswordMode {
        guard let index = raw as? Int, let mode = TablePlusPasswordMode(rawValue: index) else {
            return .storeInKeychain
        }
        return mode
    }

    var storesPasswordInKeychain: Bool {
        self == .storeInKeychain
    }

    var promptsForPassword: Bool {
        self == .askEveryTime || self == .commandLine
    }
}

struct TablePlusTLSKeySlots {
    let clientKey: Int?
    let clientCertificate: Int?
    let certificateAuthority: Int?

    static let keyCertificateAuthority = TablePlusTLSKeySlots(
        clientKey: 0,
        clientCertificate: 1,
        certificateAuthority: 2
    )
    static let certificateKeyAuthority = TablePlusTLSKeySlots(
        clientKey: nil,
        clientCertificate: 0,
        certificateAuthority: 1
    )
    static let authorityOnly = TablePlusTLSKeySlots(
        clientKey: nil,
        clientCertificate: nil,
        certificateAuthority: 0
    )
    static let none = TablePlusTLSKeySlots(clientKey: nil, clientCertificate: nil, certificateAuthority: nil)
}

struct TablePlusTLSForm {
    let modes: [SSLMode]
    let slots: TablePlusTLSKeySlots
}

enum TablePlusTLSVocabulary {
    private static let mysql = TablePlusTLSForm(
        modes: [.preferred, .disabled, .required, .verifyCa, .verifyIdentity],
        slots: .keyCertificateAuthority
    )
    private static let mariadb = TablePlusTLSForm(
        modes: [.preferred, .required, .verifyIdentity],
        slots: .keyCertificateAuthority
    )
    private static let postgres = TablePlusTLSForm(
        modes: [.preferred, .disabled, .required, .preferred, .verifyCa, .verifyIdentity],
        slots: .keyCertificateAuthority
    )
    private static let cassandra = TablePlusTLSForm(
        modes: [.disabled, .required, .verifyCa, .verifyIdentity, .verifyIdentity],
        slots: .keyCertificateAuthority
    )
    private static let redis = TablePlusTLSForm(
        modes: [.disabled, .required, .verifyCa],
        slots: .keyCertificateAuthority
    )
    private static let clickhouse = TablePlusTLSForm(
        modes: [.disabled, .verifyIdentity, .required],
        slots: .authorityOnly
    )
    private static let mongo = TablePlusTLSForm(
        modes: [.disabled, .verifyIdentity, .required],
        slots: .certificateKeyAuthority
    )
    private static let elasticsearch = TablePlusTLSForm(
        modes: [.disabled, .verifyIdentity, .verifyCa, .required],
        slots: .authorityOnly
    )
    private static let oracle = TablePlusTLSForm(
        modes: [.disabled, .required],
        slots: .none
    )
    private static let withoutPicker = TablePlusTLSForm(modes: [.preferred], slots: .none)

    private static let byDriver: [String: TablePlusTLSForm] = [
        "MySQL": mysql,
        "MariaDB": mariadb,
        "PostgreSQL": postgres,
        "Cockroach": postgres,
        "Greenplum": postgres,
        "Redshift": postgres,
        "Vertica": postgres,
        "Cassandra": cassandra,
        "Redis": redis,
        "ClickHouse": clickhouse,
        "Mongo": mongo,
        "ElasticSearch": elasticsearch,
        "Oracle": oracle
    ]

    static func form(forDriver driver: String) -> TablePlusTLSForm {
        byDriver[driver] ?? withoutPicker
    }

    static func sslMode(forDriver driver: String, tlsMode: Int) -> SSLMode? {
        let modes = form(forDriver: driver).modes
        guard tlsMode >= 0, tlsMode < modes.count else { return nil }
        return modes[tlsMode]
    }
}
