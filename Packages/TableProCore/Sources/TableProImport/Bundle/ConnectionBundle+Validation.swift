import Foundation

enum BundleViolation: Equatable, Sendable {
    case emptyRef
    case repeatedRef(BundleRef)
    case unresolvedRef(BundleRef, referrer: BundleRef)
    case unresolvedCredentials(BundleRef)
    case cycle(BundleRef)
    case tooDeep(BundleRef)

    /// Deeper than any folder or group the app creates, and shallow enough that a crafted file cannot
    /// make every query row carry a path of thousands of names.
    static let maximumNestingDepth = 32

    var message: String {
        switch self {
        case .emptyRef:
            String(localized: "an item has an empty reference")
        case .repeatedRef(let ref):
            String(format: String(localized: "the reference “%@” is used more than once"), ref.rawValue)
        case .unresolvedRef(let ref, let referrer):
            String(
                format: String(localized: "“%1$@” refers to “%2$@”, which is not in the file"),
                referrer.rawValue,
                ref.rawValue
            )
        case .unresolvedCredentials(let ref):
            String(format: String(localized: "the passwords for “%@” belong to no connection in the file"), ref.rawValue)
        case .cycle(let ref):
            String(format: String(localized: "the reference “%@” is inside itself"), ref.rawValue)
        case .tooDeep(let ref):
            String(format: String(localized: "the reference “%@” is nested too deeply"), ref.rawValue)
        }
    }

    static func first(
        connections: [BundleConnection],
        groups: [BundleGroup],
        credentialProfiles: [BundleCredentialProfile],
        credentials: [BundleRef: ExportableCredentials],
        queryFolders: [BundleQueryFolder],
        savedQueries: [BundleSavedQuery]
    ) -> BundleViolation? {
        let refLists = [
            connections.map(\.ref),
            groups.map(\.ref),
            credentialProfiles.map(\.ref),
            queryFolders.map(\.ref),
            savedQueries.map(\.ref)
        ]
        for refs in refLists {
            if let violation = identityViolation(refs) { return violation }
        }

        let connectionRefs = Set(connections.map(\.ref))
        let groupRefs = Set(groups.map(\.ref))
        let profileRefs = Set(credentialProfiles.map(\.ref))
        let folderRefs = Set(queryFolders.map(\.ref))

        var links: [(ref: BundleRef?, referrer: BundleRef, targets: Set<BundleRef>)] = []
        for connection in connections {
            links.append((connection.groupRef, connection.ref, groupRefs))
            links.append((connection.credentialProfileRef, connection.ref, profileRefs))
        }
        for group in groups {
            links.append((group.parentRef, group.ref, groupRefs))
        }
        for folder in queryFolders {
            links.append((folder.parentRef, folder.ref, folderRefs))
            links.append((folder.connectionRef, folder.ref, connectionRefs))
        }
        for query in savedQueries {
            links.append((query.folderRef, query.ref, folderRefs))
            links.append((query.connectionRef, query.ref, connectionRefs))
        }
        for link in links {
            if let ref = link.ref, !link.targets.contains(ref) {
                return .unresolvedRef(ref, referrer: link.referrer)
            }
        }

        if let orphan = credentials.keys.sorted().first(where: { !connectionRefs.contains($0) }) {
            return .unresolvedCredentials(orphan)
        }

        let groupParents = Dictionary(groups.map { ($0.ref, $0.parentRef) }, uniquingKeysWith: { first, _ in first })
        if let ref = firstCycle(groups.map(\.ref), parents: groupParents) {
            return .cycle(ref)
        }
        let folderParents = Dictionary(queryFolders.map { ($0.ref, $0.parentRef) }, uniquingKeysWith: { first, _ in first })
        if let ref = firstCycle(queryFolders.map(\.ref), parents: folderParents) {
            return .cycle(ref)
        }
        if let ref = firstTooDeep(groups.map(\.ref), parents: groupParents) {
            return .tooDeep(ref)
        }
        if let ref = firstTooDeep(queryFolders.map(\.ref), parents: folderParents) {
            return .tooDeep(ref)
        }
        return nil
    }

    /// Runs after the cycle check, so every parent chain ends.
    private static func firstTooDeep(_ refs: [BundleRef], parents: [BundleRef: BundleRef?]) -> BundleRef? {
        var depths: [BundleRef: Int] = [:]
        for start in refs {
            var path: [BundleRef] = []
            var next: BundleRef? = start
            var base = 0
            while let current = next {
                if let known = depths[current] {
                    base = known
                    break
                }
                path.append(current)
                next = parents[current] ?? nil
            }
            for (offset, ref) in path.reversed().enumerated() {
                let depth = base + offset + 1
                guard depth <= maximumNestingDepth else { return start }
                depths[ref] = depth
            }
        }
        return nil
    }

    private static func identityViolation(_ refs: [BundleRef]) -> BundleViolation? {
        var seen: Set<BundleRef> = []
        for ref in refs {
            if ref.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyRef }
            if !seen.insert(ref).inserted { return .repeatedRef(ref) }
        }
        return nil
    }

    private static func firstCycle(_ refs: [BundleRef], parents: [BundleRef: BundleRef?]) -> BundleRef? {
        var acyclic: Set<BundleRef> = []
        for start in refs {
            var path: Set<BundleRef> = []
            var next: BundleRef? = start
            while let current = next, !acyclic.contains(current) {
                guard path.insert(current).inserted else { return current }
                next = parents[current] ?? nil
            }
            acyclic.formUnion(path)
        }
        return nil
    }
}
