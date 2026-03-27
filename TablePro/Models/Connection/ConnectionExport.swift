//
//  ConnectionExport.swift
//  TablePro
//

import Foundation
import UniformTypeIdentifiers

// MARK: - Identifiable URL (for sheet binding)

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - UTType

extension UTType {
    // swiftlint:disable:next force_unwrapping
    static let tableproConnectionShare = UTType("com.tablepro.connection-share")!
}

// MARK: - Export Envelope

struct ConnectionExportEnvelope: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let appVersion: String
    let connections: [ExportableConnection]
    let groups: [ExportableGroup]?
    let tags: [ExportableTag]?
}

// MARK: - Exportable Connection

struct ExportableConnection: Codable {
    let name: String
    let host: String
    let port: Int
    let database: String
    let username: String
    let type: String
    let sshConfig: ExportableSSHConfig?
    let sslConfig: ExportableSSLConfig?
    let color: String?
    let tagName: String?
    let groupName: String?
    let safeModeLevel: String?
    let aiPolicy: String?
    let additionalFields: [String: String]?
    let redisDatabase: Int?
    let startupCommands: String?
}

// MARK: - SSH Config

struct ExportableSSHConfig: Codable {
    let enabled: Bool
    let host: String
    let port: Int
    let username: String
    let authMethod: String
    let privateKeyPath: String
    let useSSHConfig: Bool
    let agentSocketPath: String
    let jumpHosts: [ExportableJumpHost]?
    let totpMode: String?
    let totpAlgorithm: String?
    let totpDigits: Int?
    let totpPeriod: Int?
}

struct ExportableJumpHost: Codable {
    let host: String
    let port: Int
    let username: String
    let authMethod: String
    let privateKeyPath: String
}

// MARK: - SSL Config

struct ExportableSSLConfig: Codable {
    let mode: String
    let caCertificatePath: String?
    let clientCertificatePath: String?
    let clientKeyPath: String?
}

// MARK: - Group & Tag

struct ExportableGroup: Codable {
    let name: String
    let color: String?
}

struct ExportableTag: Codable {
    let name: String
    let color: String?
}

// MARK: - Path Portability

enum PathPortability {
    static func contractHome(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + String(path.dropFirst(1))
    }
}
