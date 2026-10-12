import Foundation

/// Names match trimmed and lowercased; the first spelling, the first color and the first icon win.
public struct ConnectionBundleBuilder: Sendable {
    public struct GroupComponent: Hashable, Sendable {
        public let name: String
        public let color: String?
        public let iconName: String?

        public init(name: String, color: String? = nil, iconName: String? = nil) {
            self.name = name
            self.color = color
            self.iconName = iconName
        }
    }

    public struct FolderComponent: Hashable, Sendable {
        public let name: String
        public let connection: BundleRef?

        public init(name: String, connection: BundleRef? = nil) {
            self.name = name
            self.connection = connection
        }
    }

    public struct ProfileSpec: Hashable, Sendable {
        public let name: String
        public let username: String
        public let passwordMode: BundlePasswordMode
        public let secureFieldIds: [String]

        public init(name: String, username: String, passwordMode: BundlePasswordMode, secureFieldIds: [String] = []) {
            self.name = name
            self.username = username
            self.passwordMode = passwordMode
            self.secureFieldIds = secureFieldIds
        }
    }

    private struct FolderKey: Hashable {
        let name: String
        let connection: BundleRef?
    }

    private let appVersion: String
    private let exportedAt: Date
    private var connections: [BundleConnection] = []
    private var connectionRefs: Set<BundleRef> = []
    private var repeatedConnectionRef: BundleRef?
    private var groups: [BundleGroup] = []
    private var groupPositionsByPath: [[String]: Int] = [:]
    private var tags: [BundleTag] = []
    private var tagPositions: [String: Int] = [:]
    private var profiles: [BundleCredentialProfile] = []
    private var profileRefsByName: [String: BundleRef] = [:]
    private var credentials: [BundleRef: ExportableCredentials] = [:]
    private var folders: [BundleQueryFolder] = []
    private var folderRefsByPath: [[FolderKey]: BundleRef] = [:]
    private var savedQueries: [BundleSavedQuery] = []
    private var savedQueryRefs: Set<BundleRef> = []
    private var nextSavedQueryNumber = 1

    public init(appVersion: String, exportedAt: Date = Date()) {
        self.appVersion = appVersion
        self.exportedAt = exportedAt
    }

    public mutating func addConnection(
        _ settings: ExportableConnection,
        ref: BundleRef,
        groupPath: [GroupComponent] = [],
        tags: [BundleTag] = [],
        credentialProfile: ProfileSpec? = nil,
        credentials: ExportableCredentials? = nil
    ) {
        guard connectionRefs.insert(ref).inserted else {
            if repeatedConnectionRef == nil { repeatedConnectionRef = ref }
            return
        }
        var tagNames: [String] = []
        for tag in tags {
            guard let name = ensureTag(tag), !tagNames.contains(name) else { continue }
            tagNames.append(name)
        }
        let groupRef = ensureGroupPath(groupPath)
        let profileRef = credentialProfile.flatMap { ensureProfile($0) }
        connections.append(BundleConnection(
            ref: ref,
            settings: settings,
            groupRef: groupRef,
            tagNames: tagNames,
            credentialProfileRef: profileRef
        ))
        if let credentials, !credentials.isEmpty {
            self.credentials[ref] = credentials
        }
    }

    /// A ref that is taken or empty is replaced by a fresh one; the returned ref is the one in the bundle.
    @discardableResult
    public mutating func addSavedQuery(
        name: String,
        sql: String,
        keyword: String?,
        folderPath: [FolderComponent] = [],
        connection: BundleRef?,
        ref: BundleRef? = nil
    ) -> BundleRef {
        let queryRef = claimSavedQueryRef(ref)
        let folderRef = ensureFolderPath(folderPath)
        savedQueries.append(BundleSavedQuery(
            ref: queryRef,
            name: name,
            sql: sql,
            keyword: keyword,
            folderRef: folderRef,
            connectionRef: connection
        ))
        return queryRef
    }

    /// Not added to the bundle and creates no folders; its ref comes from the same namespace as `addSavedQuery`.
    @discardableResult
    public mutating func addOversizedSavedQuery(
        name: String,
        byteCount: Int,
        folderPath: [FolderComponent] = [],
        connection: BundleRef?,
        ref: BundleRef? = nil
    ) -> OversizedSavedQuery {
        OversizedSavedQuery(
            ref: claimSavedQueryRef(ref),
            name: name,
            folderPath: folderPath.map { Self.trimmed($0.name) }.filter { !$0.isEmpty },
            connection: connection,
            byteCount: byteCount
        )
    }

    public func build() throws -> ConnectionBundle {
        if let repeatedConnectionRef {
            throw ConnectionBundleError.invalidBundle(BundleViolation.repeatedRef(repeatedConnectionRef).message)
        }
        return try ConnectionBundle(
            exportedAt: exportedAt,
            appVersion: appVersion,
            connections: connections,
            groups: groups,
            tags: tags,
            credentialProfiles: profiles,
            credentials: credentials,
            queryFolders: folders,
            savedQueries: savedQueries
        )
    }

    private mutating func ensureGroupPath(_ path: [GroupComponent]) -> BundleRef? {
        var parent: BundleRef?
        var key: [String] = []
        for component in path {
            let name = Self.trimmed(component.name)
            guard !name.isEmpty, key.count < BundleViolation.maximumNestingDepth else { continue }
            key.append(name.lowercased())
            if let position = groupPositionsByPath[key] {
                if groups[position].color == nil {
                    groups[position].color = component.color
                }
                if groups[position].iconName == nil {
                    groups[position].iconName = component.iconName
                }
                parent = groups[position].ref
                continue
            }
            let ref = BundleRef("g\(groups.count + 1)")
            groupPositionsByPath[key] = groups.count
            groups.append(BundleGroup(
                ref: ref,
                name: name,
                color: component.color,
                iconName: component.iconName,
                parentRef: parent
            ))
            parent = ref
        }
        return parent
    }

    private mutating func ensureTag(_ tag: BundleTag) -> String? {
        let name = Self.trimmed(tag.name)
        guard !name.isEmpty else { return nil }
        if let position = tagPositions[name.lowercased()] {
            if tags[position].color == nil {
                tags[position].color = tag.color
            }
            return tags[position].name
        }
        tagPositions[name.lowercased()] = tags.count
        tags.append(BundleTag(name: name, color: tag.color))
        return name
    }

    private mutating func ensureProfile(_ spec: ProfileSpec) -> BundleRef? {
        let name = Self.trimmed(spec.name)
        guard !name.isEmpty else { return nil }
        if let existing = profileRefsByName[name.lowercased()] { return existing }
        let ref = BundleRef("p\(profiles.count + 1)")
        profiles.append(BundleCredentialProfile(
            ref: ref,
            name: name,
            username: spec.username,
            passwordMode: spec.passwordMode,
            secureFieldIds: spec.secureFieldIds
        ))
        profileRefsByName[name.lowercased()] = ref
        return ref
    }

    private mutating func ensureFolderPath(_ path: [FolderComponent]) -> BundleRef? {
        var parent: BundleRef?
        var key: [FolderKey] = []
        for component in path {
            let name = Self.trimmed(component.name)
            guard !name.isEmpty, key.count < BundleViolation.maximumNestingDepth else { continue }
            key.append(FolderKey(name: name.lowercased(), connection: component.connection))
            if let existing = folderRefsByPath[key] {
                parent = existing
                continue
            }
            let ref = BundleRef("f\(folders.count + 1)")
            folders.append(BundleQueryFolder(ref: ref, name: name, parentRef: parent, connectionRef: component.connection))
            folderRefsByPath[key] = ref
            parent = ref
        }
        return parent
    }

    private mutating func claimSavedQueryRef(_ requested: BundleRef?) -> BundleRef {
        if let requested, !Self.trimmed(requested.rawValue).isEmpty, savedQueryRefs.insert(requested).inserted {
            return requested
        }
        var minted = BundleRef("q\(nextSavedQueryNumber)")
        while savedQueryRefs.contains(minted) {
            nextSavedQueryNumber += 1
            minted = BundleRef("q\(nextSavedQueryNumber)")
        }
        nextSavedQueryNumber += 1
        savedQueryRefs.insert(minted)
        return minted
    }

    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
