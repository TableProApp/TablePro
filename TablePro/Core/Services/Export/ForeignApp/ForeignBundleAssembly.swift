//
//  ForeignBundleAssembly.swift
//  TablePro
//

import Foundation
import TableProImport

enum ForeignBundleAssembly {
    static func collect(
        appName: String,
        connections: [ForeignConnectionRecord],
        savedQueries: [ForeignSavedQuery],
        credentialsAborted: Bool
    ) throws -> CollectedImport {
        guard !connections.isEmpty || !savedQueries.isEmpty else {
            throw ForeignAppImportError.noConnectionsFound
        }

        var builder = ConnectionBundleBuilder(appVersion: "\(appName) Import")
        var refsBySourceId: [String: BundleRef] = [:]
        var usedRefs: Set<String> = []

        for (index, record) in connections.enumerated() {
            let sourceId = record.sourceId.flatMap { $0.isEmpty ? nil : $0 }
            let ref = uniqueRef(base: sourceId ?? "row-\(index)", index: index, used: &usedRefs)
            if let sourceId, refsBySourceId[sourceId] == nil {
                refsBySourceId[sourceId] = ref
            }
            builder.addConnection(
                record.settings,
                ref: ref,
                groupPath: record.groupPath.map { ConnectionBundleBuilder.GroupComponent(name: $0, color: nil) },
                credentials: record.credentials
            )
        }

        var unsuggestedQueries: Set<BundleRef> = []
        var oversizedQueries: [OversizedSavedQuery] = []

        for query in savedQueries {
            let connection = query.sourceConnectionId.flatMap { refsBySourceId[$0] }
            // A query bound to a connection that is not imported still lands, global and unchecked.
            let isUnmapped = query.sourceConnectionId != nil && connection == nil
            let folderNames = connection == nil ? [appName] + query.folderPath : query.folderPath
            let folderPath = folderNames.map {
                ConnectionBundleBuilder.FolderComponent(name: $0, connection: connection)
            }

            switch query.content {
            case .text(let sql):
                let ref = builder.addSavedQuery(
                    name: query.name,
                    sql: sql,
                    keyword: query.keyword,
                    folderPath: folderPath,
                    connection: connection
                )
                if query.isAutoNamed || isUnmapped {
                    unsuggestedQueries.insert(ref)
                }
            case .oversized(let byteCount):
                oversizedQueries.append(builder.addOversizedSavedQuery(
                    name: query.name,
                    byteCount: byteCount,
                    folderPath: folderPath,
                    connection: connection
                ))
            }
        }

        return CollectedImport(
            bundle: try builder.build(),
            source: .foreignApp(name: appName),
            unsuggestedQueries: unsuggestedQueries,
            oversizedQueries: oversizedQueries,
            credentialsAborted: credentialsAborted
        )
    }

    private static func uniqueRef(base: String, index: Int, used: inout Set<String>) -> BundleRef {
        var candidate = base
        var suffix = index
        while !used.insert(candidate).inserted {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return BundleRef(candidate)
    }
}
