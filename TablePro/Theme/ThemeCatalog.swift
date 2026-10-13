import Combine
import Foundation
import os

internal struct ThemeCatalogContents: Equatable, Sendable {
    internal var themes: [ThemeDefinition]
    internal var rejected: [RejectedThemeRecord]
    internal var userFiles: [String: ThemeFile]

    internal static let empty = ThemeCatalogContents(themes: BuiltInThemes.all, rejected: [], userFiles: [:])
}

/// Where a user theme was read from and the bytes read, so a save or delete can tell that the
/// file changed on disk since and leave the newer version alone.
internal struct ThemeFile: Equatable, Sendable {
    internal let url: URL
    internal let contents: Data
}

internal struct RejectedThemeRecord: Equatable, Sendable, Identifiable {
    internal let path: String
    internal let fileName: String
    internal let reason: String

    internal var id: String { path }
}

internal enum ThemeOrigin: Sendable {
    case bundle
    case user
}

/// Owns the list. A user theme is identified by its JSON `id` but lives in whatever file it was
/// loaded from, so a save, rename or delete acts on that file rather than on `<id>.json`; the two
/// differ for any file the user named themselves. Every mutation updates the in-memory list
/// synchronously, so the activation that follows never reads a stale copy.
@MainActor
internal final class ThemeCatalog: ObservableObject {
    internal static let shared = ThemeCatalog()

    @Published internal private(set) var themes: [ThemeDefinition] = BuiltInThemes.all
    @Published internal private(set) var rejected: [RejectedThemeRecord] = []

    private var userFiles: [String: ThemeFile] = [:]
    private let userDirectory: URL
    private let bundleDirectory: URL?

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeCatalog")

    nonisolated private static let bundledOrder = [
        BuiltInThemes.defaultLightId,
        BuiltInThemes.defaultDarkId,
        "tablepro.dracula",
        "tablepro.nord",
    ]

    /// Loaded before the first activation, so a user theme in a slot is in the list the launch
    /// activation resolves against.
    internal init(
        userDirectory: URL = ThemeCatalog.defaultUserDirectory,
        bundleDirectory: URL? = Bundle.main.resourceURL
    ) {
        self.userDirectory = userDirectory
        self.bundleDirectory = bundleDirectory
        reloadSynchronously()
    }

    internal func theme(id: String) -> ThemeDefinition? {
        themes.first { $0.id == id }
    }

    internal func fileURL(for id: String) -> URL? {
        userFiles[id]?.url
    }

    internal func reloadSynchronously() {
        adopt(Self.loadContents(userDirectory: userDirectory, bundleDirectory: bundleDirectory))
    }

    internal func save(_ theme: ThemeDefinition) throws {
        guard theme.isEditable else { throw ThemeLoadError.reservedIdentifier(theme.id) }
        guard ThemeIdentifier.isValid(theme.id) else { throw ThemeLoadError.invalidIdentifier(theme.id) }

        let url: URL
        if let file = userFiles[theme.id] {
            try ensureUnchanged(file)
            url = file.url
        } else {
            url = availableURL(for: theme.id)
        }
        let data = try ThemeEncoder.data(for: theme)
        try Self.write(data, to: url)
        userFiles[theme.id] = ThemeFile(url: url, contents: data)
        upsert(theme)
    }

    internal func delete(id: String) throws {
        guard !id.hasPrefix(ThemeDefinition.builtInPrefix) else {
            throw ThemeLoadError.reservedIdentifier(id)
        }
        if let file = userFiles[id], FileManager.default.fileExists(atPath: file.url.path) {
            try ensureUnchanged(file)
            try FileManager.default.removeItem(at: file.url)
        }
        userFiles[id] = nil
        themes.removeAll { $0.id == id }
    }

    internal func rename(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var theme = theme(id: id) else { return }
        theme.name = trimmed
        try save(theme)
    }

    internal func duplicate(_ source: ThemeDefinition) throws -> ThemeDefinition {
        var copy = source
        copy.id = ThemeIdentifier.generated()
        copy.name = uniqueName(
            String(format: String(localized: "%@ Copy"), source.name)
        )
        copy.author = ""
        try save(copy)
        return copy
    }

    internal func importTheme(from url: URL) throws -> ThemeDefinition {
        let document = try ThemeDocument(data: try Data(contentsOf: url))
        var theme = document.definition()

        if !theme.isEditable || containsTheme(id: theme.id) {
            theme.id = ThemeIdentifier.generated()
        }
        if themes.contains(where: { $0.name == theme.name }) {
            theme.name = uniqueName(theme.name)
        }

        try save(theme)
        return theme
    }

    internal func exportTheme(_ theme: ThemeDefinition, to url: URL) throws {
        try ThemeEncoder.data(for: theme).write(to: url, options: .atomic)
    }

    /// "Name", then "Name 2", "Name 3", the way Finder numbers copies.
    internal func uniqueName(_ base: String) -> String {
        let taken = Set(themes.map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    /// `<id>.json`, unless that name already holds another theme or a file that failed to load,
    /// which a save must never overwrite.
    private func availableURL(for id: String) -> URL {
        let taken = Set(
            userFiles.values.map(\.url.standardizedFileURL)
                + rejected.map { URL(fileURLWithPath: $0.path).standardizedFileURL }
        )
        var candidate = userDirectory.appendingPathComponent("\(id).json", isDirectory: false)
        var index = 2
        while taken.contains(candidate.standardizedFileURL) || FileManager.default.fileExists(atPath: candidate.path) {
            candidate = userDirectory.appendingPathComponent("\(id)-\(index).json", isDirectory: false)
            index += 1
        }
        return candidate
    }

    /// A file edited or replaced outside TablePro since it was read is not overwritten or removed:
    /// the catalog reloads it and the caller reports the conflict.
    private func ensureUnchanged(_ file: ThemeFile) throws {
        guard let current = try? Data(contentsOf: file.url), current != file.contents else { return }
        reloadSynchronously()
        throw ThemeLoadError.changedOnDisk(file.url.lastPathComponent)
    }

    private func adopt(_ contents: ThemeCatalogContents) {
        themes = contents.themes
        rejected = contents.rejected
        userFiles = contents.userFiles
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
        themes.sort(by: Self.displayOrder)
    }

    // MARK: - Locations

    nonisolated internal static let defaultUserDirectory: URL =
        AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro/Themes", isDirectory: true)

    internal var themesDirectory: URL { userDirectory }

    // MARK: - Disk

    nonisolated private static func displayOrder(_ lhs: ThemeDefinition, _ rhs: ThemeDefinition) -> Bool {
        let left = bundledOrder.firstIndex(of: lhs.id) ?? Int.max
        let right = bundledOrder.firstIndex(of: rhs.id) ?? Int.max
        guard left == right else { return left < right }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    nonisolated private static func loadContents(userDirectory: URL, bundleDirectory: URL?) -> ThemeCatalogContents {
        var themes = BuiltInThemes.all
        var rejected: [RejectedThemeRecord] = []
        var userFiles: [String: ThemeFile] = [:]

        ensureDirectory(userDirectory)

        if let bundle = bundleDirectory {
            for file in jsonFiles(in: bundle) where file.lastPathComponent.hasPrefix(ThemeDefinition.builtInPrefix) {
                do {
                    let document = try ThemeDocument(data: try Data(contentsOf: file))
                    guard !themes.contains(where: { $0.id == document.id }) else { continue }
                    themes.append(document.definition())
                } catch {
                    logger.error("Bundled theme \(file.lastPathComponent) rejected: \(error.publicLogShape, privacy: .public)")
                }
            }
        }

        let files = jsonFiles(in: userDirectory)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let document = try ThemeDocument(data: data)
                guard !document.id.hasPrefix(ThemeDefinition.builtInPrefix) else {
                    throw ThemeLoadError.reservedIdentifier(document.id)
                }
                if let existing = userFiles[document.id] {
                    throw ThemeLoadError.duplicateIdentifier(document.id, existingFile: existing.url.lastPathComponent)
                }
                userFiles[document.id] = ThemeFile(url: file, contents: data)
                themes.append(document.definition())
            } catch {
                rejected.append(
                    RejectedThemeRecord(
                        path: file.path,
                        fileName: file.lastPathComponent,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        themes.sort(by: displayOrder)
        return ThemeCatalogContents(themes: themes, rejected: rejected, userFiles: userFiles)
    }

    nonisolated private static func jsonFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        do {
            return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
        } catch {
            logger.error("Failed to list \(directory.lastPathComponent): \(error)")
            return []
        }
    }

    nonisolated private static func write(_ data: Data, to url: URL) throws {
        ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
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
