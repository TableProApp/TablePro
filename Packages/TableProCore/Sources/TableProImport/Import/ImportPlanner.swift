import Foundation

public enum ImportPlanner {
    public static func plan(
        _ preview: ImportPreview,
        selection: ImportSelection,
        makeId: () -> UUID = UUID.init
    ) -> ImportPlan {
        let connections = planConnections(preview, selection: selection, makeId: makeId)
        let savedQueries = planSavedQueries(preview, selection: selection, targets: connections.targets)
        return ImportPlan(
            connections: connections.planned,
            keptConnections: connections.kept,
            tags: connections.tags,
            credentialProfiles: connections.profiles,
            queries: savedQueries.planned,
            queryStatuses: savedQueries.statuses
        )
    }
}

extension ImportPlanner {
    struct ConnectionPlan {
        var planned: [PlannedConnection] = []
        var kept: [BundleRef: UUID] = [:]
        var tags: [PlannedTag] = []
        var profiles: [PlannedCredentialProfile] = []
        var targets: [BundleRef: UUID] = [:]
    }

    static func planConnections(
        _ preview: ImportPreview,
        selection: ImportSelection,
        makeId: () -> UUID
    ) -> ConnectionPlan {
        let bundle = preview.collected.bundle
        let rules = preview.environment.rules
        let tagColors = firstTagColors(bundle.tags)
        var takenNames = Set(preview.library.connections.map { normalized($0.name) })
        var replacedTargets: Set<UUID> = []
        var tagKeys: Set<String> = []
        var profileRefs: Set<BundleRef> = []
        var plan = ConnectionPlan()

        for row in preview.connections {
            guard let resolution = selection.resolution(for: row.ref),
                  let connection = bundle.connection(row.ref)
            else { continue }

            let id: UUID
            let write: PlannedConnection.Write
            var name = row.settings.name
            switch resolution {
            case .keepExisting(let existingId):
                plan.kept[row.ref] = existingId
                plan.targets[row.ref] = existingId
                continue
            case .add:
                id = makeId()
                write = .add
            case .addCopy:
                id = makeId()
                write = .add
                name = uniqueCopyName(for: name, taken: takenNames)
            case .replace(let existingId):
                guard replacedTargets.insert(existingId).inserted else { continue }
                id = existingId
                write = .replace
            }
            takenNames.insert(normalized(name))
            plan.targets[row.ref] = id

            var settings = selection.keepsCommands
                ? row.settings
                : row.settings.withoutTunnelCommand().withoutStartupCommands()
            settings.name = name

            let tagNames = uniqueTagNames(row.tagNames)
            for tagName in tagNames where tagKeys.insert(tagName.lowercased()).inserted {
                plan.tags.append(PlannedTag(name: tagName, color: tagColors[tagName.lowercased()]))
            }

            var profileRef: BundleRef?
            if rules.supportsCredentialProfiles, let profile = bundle.credentialProfile(connection.credentialProfileRef) {
                profileRef = profile.ref
                if profileRefs.insert(profile.ref).inserted {
                    plan.profiles.append(PlannedCredentialProfile(
                        ref: profile.ref,
                        name: profile.name,
                        username: profile.username,
                        passwordMode: profile.passwordMode == .pgpass ? .pgpass : .prompt,
                        secureFieldIds: profile.secureFieldIds
                    ))
                }
            }

            plan.planned.append(PlannedConnection(
                ref: row.ref,
                id: id,
                write: write,
                settings: settings,
                groupPath: groupPath(for: connection, in: bundle, maximumDepth: rules.maximumGroupDepth),
                tagNames: tagNames,
                credentialProfileRef: profileRef,
                credentials: bundle.credentials[row.ref]
            ))
        }
        return plan
    }

    static func uniqueCopyName(for baseName: String, taken: Set<String>) -> String {
        let firstCandidate = "\(baseName) (Imported)"
        if !taken.contains(normalized(firstCandidate)) {
            return firstCandidate
        }
        var suffix = 2
        while true {
            let candidate = "\(baseName) (Imported \(suffix))"
            if !taken.contains(normalized(candidate)) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func groupPath(
        for connection: BundleConnection,
        in bundle: ConnectionBundle,
        maximumDepth: Int
    ) -> [PathComponent] {
        let components = bundle.groupChain(connection.groupRef).compactMap { group -> PathComponent? in
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : PathComponent(name: name, scope: nil, color: group.color)
        }
        return Array(components.prefix(max(maximumDepth, 0)))
    }

    private static func uniqueTagNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func firstTagColors(_ tags: [BundleTag]) -> [String: String] {
        var colors: [String: String] = [:]
        for tag in tags {
            let key = tag.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if colors[key] == nil, let color = tag.color {
                colors[key] = color
            }
        }
        return colors
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
