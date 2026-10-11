import Foundation

public enum ConnectionImportAnalyzer {
    public static func analyze(
        _ collected: CollectedImport,
        library: ImportLibrarySnapshot,
        environment: ImportEnvironment
    ) -> ImportPreview {
        let bundle = collected.bundle
        let rules = environment.rules
        let allQueries = queryRows(collected)
        let queries = rules.supportsSavedQueries ? allQueries : []

        var queryCounts: [BundleRef: Int] = [:]
        for query in queries {
            if let connection = query.connection {
                queryCounts[connection, default: 0] += 1
            }
        }

        var existingByKey: [ConnectionMatchKey: ExistingConnection] = [:]
        for existing in library.connections where existingByKey[existing.matchKey] == nil {
            existingByKey[existing.matchKey] = ExistingConnection(id: existing.id, name: existing.name)
        }

        let connections = bundle.connections.map { connection -> ConnectionRow in
            let canonicalTypeId = ConnectionTypeResolver.canonicalTypeId(
                connection.settings.type,
                registeredTypeIds: environment.registeredTypeIds
            )
            var settings = connection.settings
            if let canonicalTypeId {
                settings.type = canonicalTypeId
            }

            let duplicate = existingByKey[ConnectionMatchKey(settings)]
            let savedQueryCount = queryCounts[connection.ref] ?? 0
            let groupPath = bundle.groupChain(connection.groupRef)
                .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(max(rules.maximumGroupDepth, 0))

            return ConnectionRow(
                ref: connection.ref,
                settings: settings,
                groupPath: Array(groupPath),
                tagNames: connection.tagNames,
                duplicate: duplicate,
                warnings: warnings(for: settings, canonicalTypeId: canonicalTypeId, environment: environment),
                unsupportedTypeId: canonicalTypeId == nil ? connection.settings.type : nil,
                savedQueryCount: savedQueryCount,
                resolutions: resolutions(
                    duplicate: duplicate,
                    carriesQueries: savedQueryCount > 0,
                    source: collected.source
                ),
                isSelectedByDefault: duplicate == nil
                    && canonicalTypeId != nil
                    && !collected.unsuggestedConnections.contains(connection.ref)
            )
        }

        return ImportPreview(
            collected: collected,
            environment: environment,
            library: library,
            connections: connections,
            queries: queries
        )
    }

    private static func resolutions(
        duplicate: ExistingConnection?,
        carriesQueries: Bool,
        source: ImportSource
    ) -> [ConnectionResolution] {
        guard let duplicate else { return [.add] }
        var resolutions: [ConnectionResolution] = []
        if carriesQueries {
            resolutions.append(.keepExisting(duplicate.id))
        }
        resolutions.append(.addCopy)
        if source.offersReplace {
            resolutions.append(.replace(duplicate.id))
        }
        return resolutions
    }

    private static func queryRows(_ collected: CollectedImport) -> [QueryRow] {
        let bundle = collected.bundle
        var connectionNames: [BundleRef: String] = [:]
        for connection in bundle.connections where connectionNames[connection.ref] == nil {
            connectionNames[connection.ref] = connection.settings.name
        }

        var rows: [QueryRow] = []
        var seen: Set<InFileQueryKey> = []
        for query in bundle.savedQueries {
            let key = InFileQueryKey(
                connection: query.connectionRef,
                name: query.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                sql: query.sql.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard seen.insert(key).inserted else { continue }

            let trimmedName = query.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmedName.isEmpty ? SavedQueryName.derived(from: query.sql) : trimmedName
            let keyword = SavedQueryKeyword.normalized(query.keyword)
            let byteCount = SavedQuerySize.byteCount(name: name, sql: query.sql, keyword: keyword)
            rows.append(QueryRow(
                ref: query.ref,
                name: name,
                keyword: keyword,
                connection: query.connectionRef,
                connectionName: query.connectionRef.flatMap { connectionNames[$0] },
                folderPath: bundle.folderChain(query.folderRef)
                    .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                byteCount: byteCount,
                isTooLarge: byteCount > SavedQuerySize.maximumSyncableByteCount,
                isSuggested: !collected.unsuggestedQueries.contains(query.ref)
            ))
        }

        for oversized in collected.oversizedQueries {
            let trimmedName = oversized.name.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(QueryRow(
                ref: oversized.ref,
                name: trimmedName.isEmpty ? SavedQueryName.derived(from: "") : trimmedName,
                keyword: nil,
                connection: oversized.connection,
                connectionName: oversized.connection.flatMap { connectionNames[$0] },
                folderPath: oversized.folderPath,
                byteCount: oversized.byteCount,
                isTooLarge: true,
                isSuggested: false
            ))
        }
        return rows
    }

    private struct InFileQueryKey: Hashable {
        let connection: BundleRef?
        let name: String
        let sql: String
    }
}

private extension ConnectionImportAnalyzer {
    static func warnings(
        for settings: ExportableConnection,
        canonicalTypeId: String?,
        environment: ImportEnvironment
    ) -> [String] {
        var warnings: [String] = []
        let fileExists = environment.fileExists

        if let ssh = settings.sshConfig {
            if isMissing(ssh.privateKeyPath, fileExists: fileExists) {
                warnings.append(String(format: String(localized: "SSH private key not found: %@"), ssh.privateKeyPath))
            }
            for jump in ssh.jumpHosts ?? [] where isMissing(jump.privateKeyPath, fileExists: fileExists) {
                warnings.append(String(format: String(localized: "Jump host key not found: %@"), jump.privateKeyPath))
            }
        }

        if let ssl = settings.sslConfig {
            let certificates: [(String?, String)] = [
                (ssl.caCertificatePath, String(localized: "CA certificate not found: %@")),
                (ssl.clientCertificatePath, String(localized: "Client certificate not found: %@")),
                (ssl.clientKeyPath, String(localized: "Client key not found: %@"))
            ]
            for (path, format) in certificates {
                if let path, isMissing(path, fileExists: fileExists) {
                    warnings.append(String(format: format, path))
                }
            }
            if ssl.portableMode == nil {
                warnings.append(String(
                    format: String(localized: "SSL mode “%@” is not recognized, so the connection imports with SSL required."),
                    ssl.mode
                ))
            }
        }

        if let canonicalTypeId, let pluginName = environment.missingDriverNames[canonicalTypeId] {
            warnings.append(String(
                format: String(localized: "The %@ plugin is not installed. TablePro offers to install it on connect."),
                pluginName
            ))
        }
        return warnings
    }

    static func isMissing(_ path: String, fileExists: (String) -> Bool) -> Bool {
        let expanded = PathPortability.expandHome(path)
        return !expanded.isEmpty && !fileExists(expanded)
    }
}
