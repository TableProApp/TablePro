//
//  NavicatImporter.swift
//  TablePro
//

import Foundation
import os
import TableProImport
import TableProPluginKit
import UniformTypeIdentifiers

struct NavicatImporter: ForeignAppImporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "NavicatImporter")

    let id = "navicat"
    let displayName = "Navicat"
    let symbolName = "cylinder.split.1x2"
    let appBundleIdentifier = "com.navicat.NavicatPremium"
    let readsPasswordsFromKeychain = false

    var ncxFileURL: URL?

    var importFileTypes: [UTType]? {
        [UTType(filenameExtension: "ncx") ?? .data]
    }

    func isAvailable() -> Bool { true }

    mutating func setSelectedFile(_ url: URL) {
        ncxFileURL = url
    }

    func connectionCount() -> Int {
        (try? loadConnectionElements())?.count ?? 0
    }

    func importConnections(includePasswords: Bool) throws -> ForeignAppImportResult {
        let elements = try loadConnectionElements()
        guard !elements.isEmpty else {
            throw ForeignAppImportError.noConnectionsFound
        }

        var connections: [ExportableConnection] = []
        var credentials: [String: ExportableCredentials] = [:]

        for element in elements {
            try Task.checkCancellation()
            let index = connections.count
            connections.append(buildConnection(from: element))
            if includePasswords, let creds = buildCredentials(from: element) {
                credentials[String(index)] = creds
            }
        }

        let envelope = ConnectionExportEnvelope(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "Navicat Import",
            connections: connections,
            groups: nil,
            tags: nil,
            credentials: credentials.isEmpty ? nil : credentials
        )
        return ForeignAppImportResult(envelope: envelope, sourceName: displayName)
    }
}

// MARK: - Parsing

private extension NavicatImporter {
    func loadConnectionElements() throws -> [XMLElement] {
        guard let url = ncxFileURL else {
            throw ForeignAppImportError.fileNotFound(displayName)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ForeignAppImportError.fileNotFound(displayName)
        }

        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw ForeignAppImportError.parseError(error.localizedDescription)
        }

        let nodes = (try? document.nodes(forXPath: "//Connection")) ?? []
        return nodes.compactMap { $0 as? XMLElement }
    }

    func buildConnection(from element: XMLElement) -> ExportableConnection {
        let type = Self.mapConnType(attr(element, "ConnType"))
        let isFileBased = type == "SQLite"

        return ExportableConnection(
            name: nonEmpty(attr(element, "ConnectionName")) ?? displayName,
            host: isFileBased ? "" : (nonEmpty(attr(element, "Host")) ?? "localhost"),
            port: isFileBased ? 0 : (Int(attr(element, "Port")) ?? Self.defaultPort(for: type)),
            database: isFileBased ? attr(element, "DatabaseFileName") : attr(element, "Database"),
            username: isFileBased ? "" : attr(element, "UserName"),
            type: type,
            sshConfig: buildSSHConfig(from: element),
            sslConfig: buildSSLConfig(from: element),
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )
    }

    func buildSSHConfig(from element: XMLElement) -> ExportableSSHConfig? {
        guard attr(element, "SSH").lowercased() == "true" else { return nil }
        let usesKey = attr(element, "SSH_AuthenMethod").uppercased() != "PASSWORD"
        let keyPath = usesKey ? ForeignAppPathHelper.resolveKeyPath(attr(element, "SSH_PrivateKey")) : ""
        return ExportableSSHConfig(
            enabled: true,
            host: attr(element, "SSH_Host"),
            port: Int(attr(element, "SSH_Port")),
            username: attr(element, "SSH_UserName"),
            authMethod: usesKey ? "Private Key" : "Password",
            privateKeyPath: keyPath,
            agentSocketPath: "",
            jumpHosts: nil,
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
    }

    func buildSSLConfig(from element: XMLElement) -> ExportableSSLConfig? {
        guard attr(element, "SSL").lowercased() == "true" else { return nil }
        return ExportableSSLConfig(
            mode: Self.mapSSLMode(attr(element, "SSL_PGSSLMode")),
            caCertificatePath: nonEmpty(attr(element, "SSL_CACert")),
            clientCertificatePath: nonEmpty(attr(element, "SSL_ClientCert")),
            clientKeyPath: nonEmpty(attr(element, "SSL_ClientKey"))
        )
    }

    func buildCredentials(from element: XMLElement) -> ExportableCredentials? {
        let password = attr(element, "SavePassword").lowercased() == "true"
            ? decryptField(attr(element, "Password")) : nil
        let sshPassword = attr(element, "SSH_SavePassword").lowercased() == "true"
            ? decryptField(attr(element, "SSH_Password")) : nil
        guard password != nil || sshPassword != nil else { return nil }
        return ExportableCredentials(
            password: password,
            sshPassword: sshPassword,
            keyPassphrase: nil,
            sslClientKeyPassphrase: nil,
            totpSecret: nil,
            pluginSecureFields: nil
        )
    }

    func decryptField(_ hex: String) -> String? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = NavicatCipher.decrypt(trimmed), !value.isEmpty else {
            Self.logger.warning("Could not decrypt a Navicat password field")
            return nil
        }
        return value
    }

    func attr(_ element: XMLElement, _ name: String) -> String {
        element.attribute(forName: name)?.stringValue ?? ""
    }

    func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

// MARK: - Mapping

private extension NavicatImporter {
    static func mapConnType(_ raw: String) -> String {
        switch raw.uppercased() {
        case "MYSQL": return "MySQL"
        case "MARIADB": return "MariaDB"
        case "POSTGRESQL": return "PostgreSQL"
        case "ORACLE": return "Oracle"
        case "SQLITE": return "SQLite"
        case "SQLSERVER": return "SQL Server"
        case "MONGODB": return "MongoDB"
        default: return raw
        }
    }

    static func defaultPort(for type: String) -> Int {
        switch type {
        case "MySQL", "MariaDB": return 3_306
        case "PostgreSQL": return 5_432
        case "Oracle": return 1_521
        case "SQL Server": return 1_433
        case "MongoDB": return 27_017
        default: return 0
        }
    }

    static func mapSSLMode(_ raw: String) -> String {
        switch raw.uppercased() {
        case "VERIFY-CA": return SSLMode.verifyCa.rawValue
        case "VERIFY-FULL": return SSLMode.verifyIdentity.rawValue
        case "PREFER", "ALLOW": return SSLMode.preferred.rawValue
        default: return SSLMode.required.rawValue
        }
    }
}
