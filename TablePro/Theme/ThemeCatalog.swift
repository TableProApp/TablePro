import Foundation
import os

internal struct ThemeCatalogContents: Equatable, Sendable {
    internal var themes: [ThemeDefinition]
    internal var rejected: [RejectedThemeRecord]

    internal static let empty = ThemeCatalogContents(themes: BuiltInThemes.all, rejected: [])
}

internal struct RejectedThemeRecord: Equatable, Sendable {
    internal let path: String
    internal let fileName: String
    internal let reason: String
}

internal enum ThemeOrigin: Sendable {
    case bundle
    case registry
    case user

    internal var allowedPrefix: String? {
        switch self {
        case .bundle: return ThemeDefinition.builtInPrefix
        case .registry: return ThemeDefinition.registryPrefix
        case .user: return nil
        }
    }
}

/// Owns the list. Loading is off the main actor; every mutation updates the in-memory list
/// synchronously before anything activates, because the old storage refreshed through a detached
/// Task and a save was therefore followed by an activation of the stale copy.
@MainActor
@Observable
internal final class ThemeCatalog {
    internal static let shared = ThemeCatalog()

    internal private(set) var themes: [ThemeDefinition] = BuiltInThemes.all
    internal private(set) var rejected: [RejectedThemeRecord] = []

    @ObservationIgnored
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeCatalog")

    @ObservationIgnored
    nonisolated private static let bundledOrder = [
        BuiltInThemes.defaultLightId,
        BuiltInThemes.defaultDarkId,
        "tablepro.dracula",
        "tablepro.nord",
    ]

    /// Loaded before the first activation, not after it. The old catalog refreshed through a
    /// detached Task, so the launch activation ran against built-ins alone and a user theme in a
    /// slot resolved to the default until something else re-activated it.
    private init() {
        reloadSynchronously()
    }

    internal func theme(id: String) -> ThemeDefinition? {
        themes.first { $0.id == id }
    }

    internal func reload() async {
        let contents = await Task.detached { ThemeCatalog.loadContents() }.value
        themes = contents.themes
        rejected = contents.rejected
    }

    internal func reloadSynchronously() {
        let contents = Self.loadContents()
        themes = contents.themes
        rejected = contents.rejected
    }

    internal func save(_ theme: ThemeDefinition) throws {
        guard theme.isEditable else { throw ThemeLoadError.reservedIdentifier(theme.id) }
        try Self.write(theme, to: Self.userDirectory)
        upsert(theme)
    }

    internal func delete(id: String) throws {
        guard !id.hasPrefix(ThemeDefinition.builtInPrefix), !id.hasPrefix(ThemeDefinition.registryPrefix) else {
            throw ThemeLoadError.reservedIdentifier(id)
        }
        try Self.remove(id: id, from: Self.userDirectory)
        themes.removeAll { $0.id == id }
    }

    internal func saveRegistryTheme(_ theme: ThemeDefinition) throws {
        try Self.write(theme, to: Self.registryDirectory)
        upsert(theme)
    }

    internal func deleteRegistryTheme(id: String) throws {
        try Self.remove(id: id, from: Self.registryDirectory)
        themes.removeAll { $0.id == id }
        rejected.removeAll { $0.fileName == "\(id).json" }
    }

    internal func importTheme(from url: URL) throws -> ThemeDefinition {
        let document = try ThemeDocument(data: try Data(contentsOf: url))
        var theme = document.resolved()

        if !theme.isEditable || containsTheme(id: theme.id) {
            theme.id = ThemeIdentifier.generated()
        }

        try Self.write(theme, to: Self.userDirectory)
        upsert(theme)
        return theme
    }

    internal func exportTheme(_ theme: ThemeDefinition, to url: URL) throws {
        try ThemeEncoder.data(for: theme).write(to: url, options: .atomic)
    }

    internal func loadRegistryMeta() -> RegistryThemeMeta {
        let url = Self.registryMetaURL
        guard FileManager.default.fileExists(atPath: url.path) else { return RegistryThemeMeta() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RegistryThemeMeta.self, from: try Data(contentsOf: url))
        } catch {
            Self.logger.error("Failed to load registry meta: \(error)")
            return RegistryThemeMeta()
        }
    }

    internal func saveRegistryMeta(_ meta: RegistryThemeMeta) throws {
        Self.ensureDirectory(Self.registryDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: Self.registryMetaURL, options: .atomic)
    }

    private func containsTheme(id: String) -> Bool {
        themes.contains { $0.id == id }
    }

    private func upsert(_ theme: ThemeDefinition) {
        if let index = themes.firstIndex(where: { $0.id == theme.id }) {
            themes[index] = theme
            return
        }
        themes.append(theme)
    }

    // MARK: - Locations

    nonisolated private static let userDirectory: URL =
        AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro/Themes", isDirectory: true)

    nonisolated private static let registryDirectory: URL =
        userDirectory.appendingPathComponent("Registry", isDirectory: true)

    nonisolated private static let registryMetaURL: URL =
        registryDirectory.appendingPathComponent("registry-meta.json")

    // MARK: - Disk

    nonisolated private static func loadContents() -> ThemeCatalogContents {
        var themes = BuiltInThemes.all
        var rejected: [RejectedThemeRecord] = []

        ensureDirectory(userDirectory)
        ensureDirectory(registryDirectory)

        let sources: [(URL, ThemeOrigin)] = [
            (Bundle.main.resourceURL, .bundle),
            (registryDirectory, .registry),
            (userDirectory, .user),
        ].compactMap { url, source in url.map { ($0, source) } }

        for (directory, source) in sources {
            let loaded = load(from: directory, source: source)
            rejected.append(contentsOf: loaded.rejected)

            for theme in loaded.themes {
                if let index = themes.firstIndex(where: { $0.id == theme.id }) {
                    themes[index] = theme
                    continue
                }
                themes.append(theme)
            }
        }

        themes.sort { lhs, rhs in
            let left = bundledOrder.firstIndex(of: lhs.id) ?? Int.max
            let right = bundledOrder.firstIndex(of: rhs.id) ?? Int.max
            guard left == right else { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return ThemeCatalogContents(themes: themes, rejected: rejected)
    }

    nonisolated private static func load(
        from directory: URL,
        source: ThemeOrigin
    ) -> (themes: [ThemeDefinition], rejected: [RejectedThemeRecord]) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return ([], []) }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && $0.lastPathComponent != "registry-meta.json" }
        } catch {
            logger.error("Failed to list \(directory.lastPathComponent): \(error)")
            return ([], [])
        }

        var themes: [ThemeDefinition] = []
        var rejected: [RejectedThemeRecord] = []

        for file in files {
            if source == .bundle, !file.lastPathComponent.hasPrefix(ThemeDefinition.builtInPrefix) { continue }

            do {
                let document = try ThemeDocument(data: try Data(contentsOf: file))
                try validate(identifier: document.id, from: source)
                themes.append(document.resolved())
            } catch {
                guard source != .bundle else {
                    logger.error("Bundled theme \(file.lastPathComponent) rejected: \(error.localizedDescription)")
                    continue
                }
                rejected.append(
                    RejectedThemeRecord(
                        path: file.path,
                        fileName: file.lastPathComponent,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        return (themes, rejected)
    }

    /// A reserved prefix is accepted only from the directory that owns it. A file dropped into the
    /// user folder claiming `tablepro.` or `registry.` would otherwise shadow the real theme, be
    /// read-only because the prefix says built-in, and be impossible to delete.
    nonisolated private static func validate(identifier: String, from source: ThemeOrigin) throws {
        guard ThemeIdentifier.isValid(identifier) else {
            throw ThemeLoadError.invalidIdentifier(identifier)
        }

        let reserved = [ThemeDefinition.builtInPrefix, ThemeDefinition.registryPrefix]
        for prefix in reserved where identifier.hasPrefix(prefix) {
            guard source.allowedPrefix == prefix else {
                throw ThemeLoadError.reservedIdentifier(identifier)
            }
        }
    }

    nonisolated private static func write(_ theme: ThemeDefinition, to directory: URL) throws {
        ensureDirectory(directory)
        guard ThemeIdentifier.isValid(theme.id) else { throw ThemeLoadError.invalidIdentifier(theme.id) }
        let url = directory.appendingPathComponent("\(theme.id).json", isDirectory: false)
        try ThemeEncoder.data(for: theme).write(to: url, options: .atomic)
    }

    nonisolated private static func remove(id: String, from directory: URL) throws {
        guard ThemeIdentifier.isValid(id) else { throw ThemeLoadError.invalidIdentifier(id) }
        let url = directory.appendingPathComponent("\(id).json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    nonisolated private static func ensureDirectory(_ url: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create \(url.lastPathComponent): \(error)")
        }
    }
}
