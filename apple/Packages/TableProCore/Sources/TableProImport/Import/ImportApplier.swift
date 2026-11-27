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
        outcome.connectionIds = plan.connections.map(\.id).filter { stored.contains($0) }
        for planned in plan.connections where stored.contains(planned.id) {
            if let credentials = planned.credentials {
                outcome.passwordsNotKept += library.writeCredentials(credentials, connectionId: planned.id).secretsNotKept
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

        let projectIds = try plan.projects.isEmpty ? [:] : library.ensureProjects(plan.projects)
        let replacedIds = Set(plan.connections.filter { $0.write == .replace }.map(\.id))
        let ownProjectIds = replacedIds.isEmpty ? [:] : library.projectIds(ofSavedConnections: replacedIds)
        // The file's project wins. One it does not name, or the store could not resolve, takes the target.
        func projectId(of planned: PlannedConnection) -> UUID? {
            if let named = planned.projectRef.flatMap({ projectIds[$0] }) {
                return named
            }
            // A replaced connection stays in its project, and so its groups are matched and made there.
            if planned.write == .replace, let own = ownProjectIds[planned.id] {
                return own
            }
            return plan.targetProjectId
        }
        func scopedPath(of planned: PlannedConnection) -> [PathComponent] {
            guard let root = planned.groupPath.first else { return [] }
            let scoped = PathComponent(
                name: root.name,
                scope: projectId(of: planned),
                color: root.color,
                iconName: root.iconName
            )
            return [scoped] + planned.groupPath.dropFirst()
        }

        var paths: [[PathComponent]] = []
        var seenPaths: Set<[PathComponent]> = []
        for planned in plan.connections where !planned.groupPath.isEmpty {
            let path = scopedPath(of: planned)
            if seenPaths.insert(path).inserted {
                paths.append(path)
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
            let groupId = groupIds[scopedPath(of: planned)]
            return ResolvedConnection(
                planned: planned,
                groupId: groupId,
                tagIds: connectionTagIds,
                credentialProfileId: planned.credentialProfileRef.flatMap { createdProfiles[$0] },
                projectId: groupId == nil ? projectId(of: planned) : nil
            )
        }
    }
}
