import Foundation
import TableProImport
import TableProPluginKit

struct AWSDiscoveryAuthentication: Sendable, Equatable {
    enum Mode: String, Sendable, Equatable, CaseIterable {
        case iam
        case password
    }

    let mode: Mode
    let awsAuthValue: String
    let profileName: String
}

enum RDSConnectionBuilder {
    static let maximumHostLength = 253

    static func exportables(
        for databases: [DiscoveredDatabase],
        authentication: AWSDiscoveryAuthentication,
        existingNames: [String]
    ) -> [ExportableConnection] {
        var taken = Set(existingNames.map { $0.lowercased() })
        return databases.compactMap { database in
            guard let connection = exportable(
                for: database,
                authentication: authentication,
                takenNames: &taken
            ) else {
                return nil
            }
            return connection
        }
    }

    static func exportable(
        for database: DiscoveredDatabase,
        authentication: AWSDiscoveryAuthentication,
        takenNames: inout Set<String>
    ) -> ExportableConnection? {
        guard let type = RDSEngineCatalog.databaseType(forEngine: database.engine) else { return nil }
        guard let host = validatedHost(database.host) else { return nil }
        guard let port = database.port, (1 ... 65_535).contains(port) else { return nil }
        guard let identifier = sanitized(database.identifier) else { return nil }

        let name = uniqueName(for: database, identifier: identifier, takenNames: &takenNames)
        let usesIAM = authentication.mode == .iam && database.iamAuthenticationEnabled
        var additionalFields: [String: String] = [
            "awsAuth": usesIAM ? authentication.awsAuthValue : "off",
            "awsRegion": database.region
        ]
        if usesIAM, !authentication.profileName.isEmpty {
            additionalFields["awsProfileName"] = authentication.profileName
        }
        if !usesIAM {
            additionalFields["promptForPassword"] = "true"
        }

        return ExportableConnection(
            name: name,
            host: host,
            port: port,
            database: sanitized(database.databaseName) ?? "",
            username: usesIAM ? "" : sanitized(database.adminUsername) ?? "",
            type: type.rawValue,
            sshConfig: nil,
            sslConfig: ExportableSSLConfig(
                mode: SSLMode.required.rawValue,
                caCertificatePath: nil,
                clientCertificatePath: nil,
                clientKeyPath: nil
            ),
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: additionalFields,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )
    }

    static func validatedHost(_ host: String?) -> String? {
        guard let candidate = sanitized(host) else { return nil }
        guard candidate.count <= maximumHostLength else { return nil }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return nil }
            guard label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        }
        return candidate
    }

    static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hasControlCharacters = trimmed.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.illegalCharacters.contains($0)
        }
        return hasControlCharacters ? nil : trimmed
    }

    private static func uniqueName(
        for database: DiscoveredDatabase,
        identifier: String,
        takenNames: inout Set<String>
    ) -> String {
        var candidates: [String] = []
        switch database.kind {
        case .clusterReader:
            candidates.append(String(format: String(localized: "%@ (reader)"), identifier))
            candidates.append(String(format: String(localized: "%1$@ (reader, %2$@)"), identifier, database.region))
        case .instance, .clusterWriter:
            candidates.append(identifier)
            candidates.append(String(format: String(localized: "%1$@ (%2$@)"), identifier, database.region))
        }

        for candidate in candidates where !takenNames.contains(candidate.lowercased()) {
            takenNames.insert(candidate.lowercased())
            return candidate
        }

        let base = candidates.last ?? identifier
        var suffix = 2
        while takenNames.contains("\(base) \(suffix)".lowercased()), suffix < 1_000 {
            suffix += 1
        }
        let unique = "\(base) \(suffix)"
        takenNames.insert(unique.lowercased())
        return unique
    }
}
