import Foundation

@testable import TableProImport

enum ImportFixtures {
    static let registeredTypeIds: Set<String> = ["MySQL", "PostgreSQL", "Redis"]

    static func settings(
        name: String = "Orders",
        host: String = "db.example.com",
        port: Int = 5_432,
        database: String = "orders",
        username: String = "app",
        type: String = "PostgreSQL"
    ) -> ExportableConnection {
        ExportableConnection(name: name, host: host, port: port, database: database, username: username, type: type)
    }

    static func makeRules(
        maximumGroupDepth: Int = 3,
        supportsSavedQueries: Bool = true,
        supportsCredentialProfiles: Bool = true
    ) -> ImportRules {
        ImportRules(
            maximumGroupDepth: maximumGroupDepth,
            supportsSavedQueries: supportsSavedQueries,
            supportsCredentialProfiles: supportsCredentialProfiles
        )
    }

    static func makeEnvironment(
        rules: ImportRules = ImportFixtures.makeRules(),
        registeredTypeIds: Set<String> = ImportFixtures.registeredTypeIds,
        missingDriverNames: [String: String] = [:],
        fileExists: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> ImportEnvironment {
        ImportEnvironment(
            rules: rules,
            registeredTypeIds: registeredTypeIds,
            missingDriverNames: missingDriverNames,
            fileExists: fileExists
        )
    }

    static func existing(
        _ settings: ExportableConnection,
        id: UUID = UUID(),
        name: String? = nil
    ) -> ImportLibrarySnapshot.Connection {
        ImportLibrarySnapshot.Connection(id: id, name: name ?? settings.name, matchKey: ConnectionMatchKey(settings))
    }

    static func makeBundle(
        connections: [BundleConnection],
        groups: [BundleGroup] = [],
        tags: [BundleTag] = [],
        credentialProfiles: [BundleCredentialProfile] = [],
        credentials: [BundleRef: ExportableCredentials] = [:],
        queryFolders: [BundleQueryFolder] = [],
        savedQueries: [BundleSavedQuery] = []
    ) throws -> ConnectionBundle {
        try ConnectionBundle(
            appVersion: "Tests",
            connections: connections,
            groups: groups,
            tags: tags,
            credentialProfiles: credentialProfiles,
            credentials: credentials,
            queryFolders: queryFolders,
            savedQueries: savedQueries
        )
    }

    static func makePreview(
        _ bundle: ConnectionBundle,
        source: ImportSource = .file(name: "Tests.tablepro"),
        library: ImportLibrarySnapshot = ImportLibrarySnapshot(),
        environment: ImportEnvironment = ImportFixtures.makeEnvironment(),
        unsuggestedConnections: Set<BundleRef> = [],
        unsuggestedQueries: Set<BundleRef> = [],
        oversizedQueries: [OversizedSavedQuery] = []
    ) -> ImportPreview {
        let collected = CollectedImport(
            bundle: bundle,
            source: source,
            unsuggestedConnections: unsuggestedConnections,
            unsuggestedQueries: unsuggestedQueries,
            oversizedQueries: oversizedQueries
        )
        return ConnectionImportAnalyzer.analyze(collected, library: library, environment: environment)
    }

    static func credentials(password: String) -> ExportableCredentials {
        ExportableCredentials(
            password: password,
            sshPassword: nil,
            keyPassphrase: nil,
            sslClientKeyPassphrase: nil,
            totpSecret: nil,
            pluginSecureFields: nil
        )
    }

    static func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }
}

struct SequentialIds {
    private var last: UInt8 = 0

    mutating func next() -> UUID {
        last += 1
        return ImportFixtures.uuid(last)
    }
}

extension ImportPlanner {
    static func plan(_ preview: ImportPreview, selection: ImportSelection, ids: inout SequentialIds) -> ImportPlan {
        plan(preview, selection: selection) { ids.next() }
    }
}
