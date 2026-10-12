import Foundation

public enum ImportApplier {
    @MainActor
    public static func apply(
        _ plan: ImportPlan,
        library: any ImportLibraryStore,
        savedQueries: (any SavedQueryImportStore)?
    ) async -> ImportOutcome {
        var outcome = ImportOutcome()

        let resolved: [ResolvedConnection]
        do {
            resolved = try resolveConnections(plan, library: library)
        } catch {
            outcome.failure = .libraryUnreadable
            return outcome
        }

        let write: ConnectionImportWrite
        if resolved.isEmpty {
            write = ConnectionImportWrite(added: [], replaced: [])
        } else {
            guard let saved = library.writeConnections(resolved) else {
                outcome.failure = .connectionsNotSaved
                return outcome
            }
            write = saved
        }
        outcome.connectionsAdded = write.added.count
        outcome.connectionsReplaced = write.replaced.count

        var stored = Set(write.added).union(write.replaced)
        for planned in plan.connections where stored.contains(planned.id) {
            if let credentials = planned.credentials {
                library.writeCredentials(credentials, connectionId: planned.id)
            }
        }
        if !plan.keptConnections.isEmpty {
            stored.formUnion(Set(plan.keptConnections.values).intersection(library.existingConnectionIds()))
        }

        let queries = plan.queries.filter { query in
            query.connectionId.map { stored.contains($0) } ?? true
        }
        outcome.savedQueriesNotImported = plan.queries.count - queries.count
        guard !queries.isEmpty else { return outcome }
        guard let savedQueries else {
            outcome.savedQueriesNotImported += queries.count
            return outcome
        }
        guard let result = await savedQueries.importSavedQueries(queries) else {
            outcome.failure = .savedQueriesNotSaved
            return outcome
        }
        outcome.savedQueriesAdded = result.insertedIds.count
        outcome.savedQueriesNotImported += result.alreadySaved + result.tooLarge
        return outcome
    }

    @MainActor
    private static func resolveConnections(
        _ plan: ImportPlan,
        library: any ImportLibraryStore
    ) throws -> [ResolvedConnection] {
        let createdProfiles = try plan.credentialProfiles.isEmpty
            ? [:]
            : library.addImportedProfiles(plan.credentialProfiles)

        var paths: [[PathComponent]] = []
        var seenPaths: Set<[PathComponent]> = []
        for planned in plan.connections where !planned.groupPath.isEmpty {
            if seenPaths.insert(planned.groupPath).inserted {
                paths.append(planned.groupPath)
            }
        }
        let leaves = try paths.isEmpty ? [] : library.ensureGroupPaths(paths)
        var groupIds: [[PathComponent]: UUID] = [:]
        for (path, leaf) in zip(paths, leaves) {
            groupIds[path] = leaf
        }

        let tagIds = try plan.tags.isEmpty ? [:] : library.ensureTags(plan.tags)

        return plan.connections.map { planned in
            var seenTags: Set<UUID> = []
            let connectionTagIds = planned.tagNames
                .compactMap { tagIds[$0.lowercased()] }
                .filter { seenTags.insert($0).inserted }
            return ResolvedConnection(
                planned: planned,
                groupId: groupIds[planned.groupPath],
                tagIds: connectionTagIds,
                credentialProfileId: planned.credentialProfileRef.flatMap { createdProfiles[$0] }
            )
        }
    }
}
