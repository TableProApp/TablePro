import AppKit
import Combine
import Foundation
import os
import TableProSyncTransport
import TableProTheme

internal struct ThemeCatalogContents: Equatable, Sendable {
    internal var themes: [ThemeDefinition]
    internal var rejected: [RejectedThemeRecord]
    internal var userFiles: [String: ThemeFile]

    internal static let empty = ThemeCatalogContents(themes: BuiltInThemes.all, rejected: [], userFiles: [:])
}

// Where a user theme was read from and the bytes read, so a save or a move to the Trash can tell
// that the file changed on disk since and leave the newer version alone.
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

// `themeId` is nil for a file that never loaded as a theme, which never synced either.
internal struct ThemeTrashReceipt: Equatable, Sendable {
    internal let themeId: String?
    internal let originalURL: URL
    internal let trashedURL: URL
    // Only the deletions the trash queued: one queued before it, such as a cleared value color, stays.
    internal var tombstones: [String] = []
}

internal struct ThemeFileTrash: Sendable {
    internal let moveToTrash: @Sendable (URL) throws -> URL

    internal static let system = ThemeFileTrash { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let trashed = resulting as URL? else { throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: url]) }
        return trashed
    }

    // One folder per item, so two trashed files with one name never collide.
    internal static func folder(_ directory: URL) -> ThemeFileTrash {
        ThemeFileTrash { url in
            let holder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
            let trashed = holder.appendingPathComponent(url.lastPathComponent, isDirectory: false)
            try FileManager.default.moveItem(at: url, to: trashed)
            return trashed
        }
    }

    // A sandboxed run trashes inside its sandbox, never into the user's Trash.
    internal static func resolved(in environment: AppStorageEnvironment) -> ThemeFileTrash {
        environment.trashDirectory.map(folder) ?? .system
    }
}

// Owns the list. A user theme is identified by its JSON `id` but lives in whatever file it was
// loaded from, so a save, rename or move to the Trash acts on that file rather than on `<id>.json`;
// the two differ for any file the user named themselves. Every mutation updates the in-memory list
// synchronously, and the list reloads whenever TablePro becomes active, so a theme fixed, dropped
// or removed in Finder is picked up without a view asking.
@MainActor
internal final class ThemeCatalog: ObservableObject {
    internal static let shared = ThemeCatalog()

    @Published internal private(set) var themes: [ThemeDefinition] = BuiltInThemes.all
    @Published internal private(set) var rejected: [RejectedThemeRecord] = []

    // What the files hold. `themes` is this with colliding names told apart for display.
    private var loaded: [ThemeDefinition] = BuiltInThemes.all
    private var userFiles: [String: ThemeFile] = [:]
    // Themes whose file went away since it was read. A save of one is refused rather than writing a
    // new file, which would bring back a theme deleted in Finder or on another Mac.
    private var vanished: [String: URL] = [:]
    private let userDirectory: URL
    private let bundleDirectory: URL?
    private let fileTrash: ThemeFileTrash
    private let syncTracker: SyncChangeTracker
    private var activationCancellable: AnyCancellable?

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeCatalog")

    // Loaded before the first activation, so a user theme in a slot is in the list the launch
    // activation resolves against.
    internal init(
        userDirectory: URL = ThemeCatalog.defaultUserDirectory,
        bundleDirectory: URL? = Bundle.main.resourceURL,
        notificationCenter: NotificationCenter = .default,
        fileTrash: ThemeFileTrash = .resolved(in: .shared),
        syncTracker: SyncChangeTracker = .shared
    ) {
        self.userDirectory = userDirectory
        self.bundleDirectory = bundleDirectory
        self.fileTrash = fileTrash
        self.syncTracker = syncTracker
        reloadSynchronously()
        activationCancellable = notificationCenter
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reloadSynchronously() }
    }

    internal func theme(id: String) -> ThemeDefinition? {
        themes.first { $0.id == id }
    }

    // As its file holds it: `theme(id:)` can carry a name changed to tell two themes apart, which
    // an editor must not write back.
    internal func storedTheme(id: String) -> ThemeDefinition? {
        loaded.first { $0.id == id }
    }

    internal func fileURL(for id: String) -> URL? {
        userFiles[id]?.url
    }

    internal func reloadSynchronously() {
        adopt(Self.loadContents(userDirectory: userDirectory, bundleDirectory: bundleDirectory))
    }

    // Writes the theme to the file it came from, or a new theme to `<id>.json`. The list then holds
    // what the file holds, which the format normalizes.
    internal func save(_ theme: ThemeDefinition) throws {
        let previous = userFiles[theme.id] != nil ? storedTheme(id: theme.id) : nil
        try persist(theme)
        markSyncEdit(of: storedTheme(id: theme.id) ?? theme, previous: previous)
    }

    // Each record pushes whole, so one whose keys did not change would revert another Mac's edit of them.
    private func markSyncEdit(of theme: ThemeDefinition, previous: ThemeDefinition?) {
        guard let previous else {
            syncTracker.markDirty(.settings, ids: Self.syncCategories(of: theme))
            return
        }
        let cleared = Self.newerSyncSchemas.filter { !theme.setsSlots(introducedIn: $0) && previous.setsSlots(introducedIn: $0) }
        let changed = ([ThemeSchema.oldestReadable] + Self.newerSyncSchemas)
            .filter { !cleared.contains($0) && !Self.ownedKeysMatch(theme, previous, schema: $0) }
        syncTracker.markDirty(.settings, ids: changed.map { Self.syncCategory(for: theme.id, schema: $0) })
        syncTracker.markDeleted(.settings, ids: cleared.map { Self.syncCategory(for: theme.id, schema: $0) })
    }

    private func persist(_ theme: ThemeDefinition) throws {
        guard theme.isEditable else { throw ThemeLoadError.reservedIdentifier(theme.id) }
        guard ThemeIdentifier.isValid(theme.id) else { throw ThemeLoadError.invalidIdentifier(theme.id) }

        let url: URL
        if let file = userFiles[theme.id] {
            try ensureUnchanged(file)
            url = file.url
        } else {
            try ensureNotVanished(theme.id)
            url = availableURL(for: theme.id)
        }
        let data = try ThemeFileFormat.encode(theme)
        try Self.write(data, to: url)
        userFiles[theme.id] = ThemeFile(url: url, contents: data)
        upsert(try ThemeFileFormat.decode(data))
    }

    @discardableResult
    internal func trash(id: String) throws -> ThemeTrashReceipt {
        guard !id.hasPrefix(ThemeDefinition.builtInPrefix) else {
            throw ThemeLoadError.reservedIdentifier(id)
        }
        guard let file = userFiles[id] else {
            try ensureNotVanished(id)
            throw CocoaError(.fileNoSuchFile)
        }
        try ensureUnchanged(file)
        let trashed = try fileTrash.moveToTrash(file.url)
        userFiles[id] = nil
        vanished[id] = file.url
        publish(loaded.filter { $0.id != id })
        // Another Mac may have set a value color this one has not pulled yet.
        let categories = Self.allSyncCategories(for: id)
        let queued = syncTracker.tombstonedIds(for: .settings)
        syncTracker.markDeleted(.settings, ids: categories)
        return ThemeTrashReceipt(
            themeId: id,
            originalURL: file.url,
            trashedURL: trashed,
            tombstones: categories.filter { !queued.contains($0) }
        )
    }

    @discardableResult
    internal func trashRejected(path: String) throws -> ThemeTrashReceipt {
        guard let record = rejected.first(where: { $0.path == path }) else { throw CocoaError(.fileNoSuchFile) }
        let url = URL(fileURLWithPath: record.path)
        let trashed = try fileTrash.moveToTrash(url)
        reloadSynchronously()
        return ThemeTrashReceipt(themeId: nil, originalURL: url, trashedURL: trashed)
    }

    internal func restore(_ receipt: ThemeTrashReceipt) throws {
        try FileManager.default.moveItem(at: receipt.trashedURL, to: receipt.originalURL)
        reloadSynchronously()
        guard let id = receipt.themeId, userFiles[id] != nil, let restored = storedTheme(id: id) else { return }
        let categories = Self.syncCategories(of: restored)
        syncTracker.markDirty(.settings, ids: categories)
        // A record the restored theme does not hold may carry another Mac's keys, which the queued deletion would remove.
        syncTracker.discardTombstones(.settings, ids: receipt.tombstones.filter { !categories.contains($0) })
    }

    // Two themes with one name cannot be told apart in a popup, so a taken name is refused rather
    // than numbered behind the user's back.
    internal func rename(id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var theme = storedTheme(id: id) else {
            try ensureNotVanished(id)
            return
        }
        guard trimmed != theme.name else { return }
        guard !isNameTaken(trimmed, byOtherThan: id) else { throw ThemeLoadError.nameTaken(trimmed) }
        theme.name = trimmed
        try save(theme)
    }

    internal func duplicate(_ source: ThemeDefinition) throws -> ThemeDefinition {
        var copy = source
        copy.id = ThemeIdentifier.generated()
        copy.name = firstFreeName { reserved in Self.copyName(of: source.name, reserving: reserved) }
        copy.author = ""
        try save(copy)
        return theme(id: copy.id) ?? copy
    }

    internal func importTheme(from url: URL) throws -> ThemeDefinition {
        var imported = try ThemeFileImporter.importTheme(at: url)
        imported.name = uniqueName(imported.name)
        try save(imported)
        return theme(id: imported.id) ?? imported
    }

    internal func exportTheme(_ theme: ThemeDefinition, to url: URL) throws {
        try ThemeFileFormat.encode(theme).write(to: url, options: .atomic)
    }

    // "Name", then "Name 2", "Name 3", the way Finder numbers copies.
    internal func uniqueName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return firstFreeName { reserved in Self.shortened(trimmed, toFit: reserved) }
    }

    private func firstFreeName(_ name: (_ reserved: Int) -> String) -> String {
        firstFreeName(isTaken: { isNameTaken($0, byOtherThan: nil) }, name)
    }

    private func firstFreeName(isTaken: (String) -> Bool, _ name: (_ reserved: Int) -> String) -> String {
        let first = name(0)
        guard isTaken(first) else { return first }
        var index = 2
        while true {
            let suffix = " \(index)"
            let candidate = name(suffix.count) + suffix
            guard isTaken(candidate) else { return candidate }
            index += 1
        }
    }

    // The format caps a name, so a number or "Copy" shortens the name itself instead of making one
    // the save then refuses.
    nonisolated private static func shortened(_ name: String, toFit reserved: Int) -> String {
        let room = ThemeFileFormat.maximumTextLength - reserved
        guard name.count > room else { return name }
        return String(name.prefix(max(room, 0))).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func copyName(of name: String, reserving reserved: Int) -> String {
        let format = String(localized: "%@ Copy")
        let overhead = String(format: format, "").count
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(format: format, shortened(trimmed, toFit: overhead + reserved))
    }

    private func isNameTaken(_ name: String, byOtherThan id: String?) -> Bool {
        themes.contains { theme in
            theme.id != id
                && theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    // `<id>.json`, unless that name already holds another theme or a file that failed to load,
    // which a save must never overwrite.
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

    // A file edited, replaced or removed outside TablePro since it was read is not overwritten,
    // moved or recreated: the catalog reloads and the caller reports the conflict.
    private func ensureUnchanged(_ file: ThemeFile) throws {
        let current: Data
        do {
            current = try Data(contentsOf: file.url)
        } catch {
            reloadSynchronously()
            throw ThemeLoadError.deletedOnDisk(file.url.lastPathComponent)
        }
        guard current != file.contents else { return }
        reloadSynchronously()
        throw ThemeLoadError.changedOnDisk(file.url.lastPathComponent)
    }

    // A file that is still there no longer loads as this theme, so it changed rather than went away.
    private func ensureNotVanished(_ id: String) throws {
        guard let url = vanished[id] else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThemeLoadError.deletedOnDisk(url.lastPathComponent)
        }
        throw ThemeLoadError.changedOnDisk(url.lastPathComponent)
    }

    private func adopt(_ contents: ThemeCatalogContents) {
        for (id, file) in userFiles where contents.userFiles[id] == nil {
            vanished[id] = file.url
        }
        for id in contents.userFiles.keys {
            vanished[id] = nil
        }
        userFiles = contents.userFiles
        publish(contents.themes)
        if rejected != contents.rejected {
            rejected = contents.rejected
        }
    }

    private func upsert(_ theme: ThemeDefinition) {
        publish(loaded.filter { $0.id != theme.id } + [theme])
    }

    // `loaded` first: `$themes` subscribers read `storedTheme(id:)` while the list is published.
    private func publish(_ list: [ThemeDefinition]) {
        loaded = ThemeOrdering.sorted(list)
        let shown = Self.distinguishingNames(in: loaded)
        if themes != shown {
            themes = shown
        }
    }

    // Two themes with one name cannot be told apart in a popup, and sync makes that routine: two
    // Macs each make an "Ocean". The later one in display order shows "Ocean 2". Only the list
    // changes, never the file, so a display fix is never written, synced and fixed again elsewhere.
    nonisolated private static func distinguishingNames(in themes: [ThemeDefinition]) -> [ThemeDefinition] {
        var taken: Set<String> = []
        return themes.map { theme in
            let base = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var name = base
            var index = 2
            while taken.contains(name.folding(options: .caseInsensitive, locale: nil)) {
                name = "\(base) \(index)"
                index += 1
            }
            taken.insert(name.folding(options: .caseInsensitive, locale: nil))
            guard name != theme.name else { return theme }
            var shown = theme
            shown.name = name
            return shown
        }
    }

    // MARK: - Locations

    nonisolated internal static let defaultUserDirectory: URL =
        AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro/Themes", isDirectory: true)

    internal var themesDirectory: URL { userDirectory }

    // MARK: - Disk

    nonisolated private static func loadContents(userDirectory: URL, bundleDirectory: URL?) -> ThemeCatalogContents {
        var themes = BuiltInThemes.all
        var rejected: [RejectedThemeRecord] = []
        var userFiles: [String: ThemeFile] = [:]

        ensureDirectory(userDirectory)

        if let bundle = bundleDirectory {
            for file in jsonFiles(in: bundle) where file.lastPathComponent.hasPrefix(ThemeDefinition.builtInPrefix) {
                do {
                    let theme = try ThemeFileFormat.decode(try Data(contentsOf: file))
                    guard !themes.contains(where: { $0.id == theme.id }) else { continue }
                    themes.append(theme)
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
                let theme = try ThemeFileFormat.decode(data, text: .repaired)
                guard !theme.id.hasPrefix(ThemeDefinition.builtInPrefix) else {
                    throw ThemeLoadError.reservedIdentifier(theme.id)
                }
                if let existing = userFiles[theme.id] {
                    throw ThemeLoadError.duplicateIdentifier(theme.id, existingFile: existing.url.lastPathComponent)
                }
                userFiles[theme.id] = ThemeFile(url: file, contents: data)
                themes.append(theme)
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

        return ThemeCatalogContents(themes: ThemeOrdering.sorted(themes), rejected: rejected, userFiles: userFiles)
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

// MARK: - Sync

// How a synced theme meets a local file that holds its id.
internal enum ThemeRemoteMerge: Sendable {
    // The local file is a synced copy, so the record replaces it.
    case replace
    // The local file may never have reached the server, so a version that differs stays as its own theme.
    case keepBoth
}

// Each user theme syncs as the settings record `theme.<id>`, holding only the keys format 3 reads, so the
// previous stable reads and edits it. A theme that sets a key a newer format introduced also syncs
// `themeSchema<N>.<id>`. Each record owns its own keys, and every payload is a canonical file.
internal extension ThemeCatalog {
    nonisolated static let syncCategoryPrefix = "theme."
    // Never under `theme.`: a build that reads only format 3 passes over a category it does not know.
    nonisolated static let schemaSyncCategoryPrefix = "themeSchema"

    nonisolated static let newerSyncSchemas = Array(
        stride(from: ThemeSchema.oldestReadable + 1, through: ThemeSchema.current, by: 1)
    )

    // Themes are about 1.2 KB, and a slot path nests three containers deep, so anything past these
    // limits is not a theme and only costs parse time.
    nonisolated static let maximumSyncPayloadSize = 64 * 1_024
    nonisolated static let maximumSyncPayloadDepth = 4

    nonisolated static func syncCategory(for id: String) -> String {
        syncCategoryPrefix + id
    }

    nonisolated static func syncCategory(for id: String, schema: Int) -> String {
        guard schema > ThemeSchema.oldestReadable else { return syncCategory(for: id) }
        return "\(schemaSyncCategoryPrefix)\(schema).\(id)"
    }

    nonisolated static func syncCategories(of theme: ThemeDefinition) -> [String] {
        [syncCategory(for: theme.id)]
            + newerSyncSchemas.filter(theme.setsSlots(introducedIn:)).map { syncCategory(for: theme.id, schema: $0) }
    }

    nonisolated static func themeId(forSyncCategory category: String) -> String? {
        syncRecord(forCategory: category)?.id
    }

    nonisolated static func syncSchema(forCategory category: String) -> Int? {
        syncRecord(forCategory: category)?.schema
    }

    nonisolated private static func syncRecord(forCategory category: String) -> (id: String, schema: Int)? {
        if category.hasPrefix(syncCategoryPrefix) {
            return (String(category.dropFirst(syncCategoryPrefix.count)), ThemeSchema.oldestReadable)
        }
        guard category.hasPrefix(schemaSyncCategoryPrefix) else { return nil }
        let rest = category.dropFirst(schemaSyncCategoryPrefix.count)
        guard let dot = rest.firstIndex(of: "."),
              let schema = Int(rest[..<dot]),
              String(schema) == rest[..<dot],
              schema > ThemeSchema.oldestReadable
        else { return nil }
        return (String(rest[rest.index(after: dot)...]), schema)
    }

    // `theme.<id>` owns the format 3 slots, the name, the author and the appearance; a newer format's record
    // owns only the slots that format introduced.
    nonisolated private static func ownedKeysMatch(_ lhs: ThemeDefinition, _ rhs: ThemeDefinition, schema: Int) -> Bool {
        let owned: (ThemeSlot) -> Bool = schema > ThemeSchema.oldestReadable
            ? { $0.introducedInSchema == schema }
            : { $0.introducedInSchema <= ThemeSchema.oldestReadable }
        let slotsMatch = lhs.overrides.filter { owned($0.key) } == rhs.overrides.filter { owned($0.key) }
        guard schema <= ThemeSchema.oldestReadable else { return slotsMatch }
        return slotsMatch && lhs.name == rhs.name && lhs.author == rhs.author && lhs.appearance == rhs.appearance
    }

    nonisolated private static func allSyncCategories(for id: String) -> [String] {
        [syncCategory(for: id)] + newerSyncSchemas.map { syncCategory(for: id, schema: $0) }
    }

    var syncCategories: [String] {
        userFiles.keys.sorted().flatMap { id in
            storedTheme(id: id).map(Self.syncCategories(of:)) ?? [Self.syncCategory(for: id)]
        }
    }

    // The file's own name, never the one the list shows to tell two themes apart. A newer format's
    // record exists only while the theme sets one of its keys.
    func syncPayload(forCategory category: String) -> Data? {
        guard let record = Self.syncRecord(forCategory: category),
              userFiles[record.id] != nil,
              let theme = storedTheme(id: record.id),
              record.schema == ThemeSchema.oldestReadable || theme.setsSlots(introducedIn: record.schema)
        else { return nil }
        do {
            return try ThemeFileFormat.encode(theme.restricted(toSchema: record.schema))
        } catch {
            Self.logger.error("Could not encode a theme for sync: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    // A synced theme is untrusted input from another device, so it is validated before anything
    // touches disk. A record that fails validation is skipped, since the same bytes would fail
    // again; only a disk failure is `.failed`, so the pull is not acknowledged and replays.
    func applyRemote(
        category: String,
        data: Data,
        merge: ThemeRemoteMerge = .replace,
        newerRecord: (String) -> Data? = { _ in nil }
    ) -> RemoteApplyOutcome {
        let record: (schema: Int, theme: ThemeDefinition)
        do {
            record = try Self.validatedRemoteTheme(category: category, data: data)
        } catch {
            Self.logger.error(
                "Skipped synced theme \(category, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)"
            )
            return .skipped
        }

        do {
            reloadIfChangedOnDisk(record.theme.id)
            guard record.schema > ThemeSchema.oldestReadable else {
                return try writeRemote(mergedTheme(record.theme, merge: merge, newerRecord: newerRecord), merge: merge)
            }
            return try applyRemoteSlots(of: record.theme, introducedIn: record.schema, merge: merge)
        } catch {
            Self.logger.error(
                "Could not write synced theme \(category, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)"
            )
            return .failed
        }
    }

    // The other Mac moved its copy to the Trash, so this one does too rather than deleting for good.
    @discardableResult
    func removeWithoutSync(ids: Set<String>) -> Bool {
        var isPersisted = true
        var removed: Set<String> = []
        for id in ids.sorted() {
            // A file replaced since the last load may now hold another theme, which nothing deleted.
            reloadIfChangedOnDisk(id)
            guard let file = userFiles[id] else { continue }
            do {
                _ = try fileTrash.moveToTrash(file.url)
            } catch where !FileManager.default.fileExists(atPath: file.url.path) {
                Self.logger.info("A theme deleted on another Mac was already gone here")
            } catch {
                Self.logger.error("Could not remove a theme deleted on another Mac: \(error.publicLogShape, privacy: .public)")
                isPersisted = false
                continue
            }
            userFiles[id] = nil
            vanished[id] = file.url
            removed.insert(id)
        }
        if !removed.isEmpty {
            publish(loaded.filter { !removed.contains($0.id) })
        }
        syncTracker.discardDirty(.settings, ids: removed.sorted().flatMap(Self.allSyncCategories(for:)))
        return isPersisted
    }

    // Another Mac cleared the theme's last key of `schema`, so this one clears that format's keys too.
    @discardableResult
    func removeSlotsWithoutSync(introducedIn schema: Int, ids: Set<String>) -> Bool {
        var isPersisted = true
        var settled: [String] = []
        for id in ids.sorted() {
            reloadIfChangedOnDisk(id)
            guard userFiles[id] != nil, let local = storedTheme(id: id) else { continue }
            settled.append(id)
            guard local.setsSlots(introducedIn: schema) else { continue }
            var cleared = local
            cleared.overrides = local.overrides.filter { $0.key.introducedInSchema != schema }
            do {
                _ = try writeRemote(cleared, merge: .replace)
            } catch {
                Self.logger.error("Could not clear keys deleted on another Mac: \(error.publicLogShape, privacy: .public)")
                settled.removeLast()
                isPersisted = false
            }
        }
        syncTracker.discardDirty(.settings, ids: settled.map { Self.syncCategory(for: $0, schema: schema) })
        return isPersisted
    }

    // `theme.<id>` owns only the keys format 3 reads, so a theme this Mac holds keeps its newer keys.
    // One new here, or one whose local file may never have reached the server, takes them from their records.
    private func mergedTheme(
        _ record: ThemeDefinition,
        merge: ThemeRemoteMerge,
        newerRecord: (String) -> Data?
    ) -> ThemeDefinition {
        let base = record.restricted(toSchema: ThemeSchema.oldestReadable)
        if merge == .replace, userFiles[record.id] != nil, let local = storedTheme(id: record.id) {
            return base.replacingSlots(from: local) { $0.introducedInSchema > ThemeSchema.oldestReadable }
        }
        return Self.newerSyncSchemas.reduce(base) { merged, schema in
            let category = Self.syncCategory(for: record.id, schema: schema)
            guard let data = newerRecord(category),
                  let newer = try? Self.validatedRemoteTheme(category: category, data: data)
            else { return merged }
            return merged.replacingSlots(from: newer.theme) { $0.introducedInSchema == schema }
        }
    }

    // A theme new to this Mac takes these keys when its `theme.<id>` arrives. While the local file may
    // never have reached the server, `theme.<id>` decides the whole theme and what is kept as a copy.
    private func applyRemoteSlots(
        of record: ThemeDefinition,
        introducedIn schema: Int,
        merge: ThemeRemoteMerge
    ) throws -> RemoteApplyOutcome {
        guard merge == .replace, userFiles[record.id] != nil, let local = storedTheme(id: record.id) else {
            return .skipped
        }
        let merged = local.replacingSlots(from: record) { $0.introducedInSchema == schema }
        guard merged != local else { return .skipped }
        return try writeRemote(merged, merge: .replace)
    }

    private func writeRemote(_ theme: ThemeDefinition, merge: ThemeRemoteMerge) throws -> RemoteApplyOutcome {
        let data = try ThemeFileFormat.encode(theme)
        let url: URL
        var keptCopy: ThemeDefinition?
        if let file = userFiles[theme.id] {
            guard file.contents != data else { return .skipped }
            // Compared as themes: 0.81 wrote the same theme with other bytes.
            if merge == .keepBoth, let local = storedTheme(id: theme.id), local != theme {
                keptCopy = try keepCopy(of: local, besides: theme)
            }
            url = file.url
        } else {
            url = availableURL(for: theme.id)
        }
        do {
            try Self.write(data, to: url)
        } catch {
            if let keptCopy {
                discardCopy(keptCopy)
            }
            throw error
        }
        vanished[theme.id] = nil
        userFiles[theme.id] = ThemeFile(url: url, contents: data)
        upsert(try ThemeFileFormat.decode(data))
        // A pull suppresses this mark; the seed that follows it uploads the copy, which the server lacks.
        if let keptCopy {
            syncTracker.markDirty(.settings, ids: Self.syncCategories(of: keptCopy))
        }
        return .applied
    }

    // A new id, so the record and the version only this Mac held both stay. The copy keeps its name
    // unless the arriving theme or another one shows it.
    private func keepCopy(of local: ThemeDefinition, besides incoming: ThemeDefinition) throws -> ThemeDefinition {
        var copy = local
        copy.id = ThemeIdentifier.generated()
        copy.name = firstFreeName(
            isTaken: { candidate in
                candidate.compare(incoming.name, options: .caseInsensitive) == .orderedSame
                    || isNameTaken(candidate, byOtherThan: incoming.id)
            },
            { reserved in Self.shortened(local.name, toFit: reserved) }
        )
        try persist(copy)
        return copy
    }

    // The record did not land, so it arrives again; a copy left behind would be made again with it.
    private func discardCopy(_ copy: ThemeDefinition) {
        guard let file = userFiles[copy.id] else { return }
        do {
            try FileManager.default.removeItem(at: file.url)
        } catch {
            Self.logger.error("Could not remove a kept theme copy: \(error.publicLogShape, privacy: .public)")
            return
        }
        userFiles[copy.id] = nil
        publish(loaded.filter { $0.id != copy.id })
    }

    // The write never lands on bytes the catalog has not read: a file changed outside TablePro is
    // read again first, and one that no longer loads as this theme is never a target.
    private func reloadIfChangedOnDisk(_ id: String) {
        guard let file = userFiles[id], (try? Data(contentsOf: file.url)) != file.contents else { return }
        reloadSynchronously()
    }

    nonisolated private static func validatedRemoteTheme(
        category: String,
        data: Data
    ) throws -> (schema: Int, theme: ThemeDefinition) {
        guard let record = syncRecord(forCategory: category),
              ThemeIdentifier.isValid(record.id),
              !record.id.hasPrefix(ThemeDefinition.builtInPrefix)
        else { throw ThemeSyncRejection.invalidCategory }
        guard record.schema <= ThemeSchema.current else { throw ThemeSyncRejection.newerFormat(record.schema) }
        guard data.count <= maximumSyncPayloadSize else { throw ThemeSyncRejection.tooLarge(data.count) }
        guard JSONNesting.depth(of: data, stoppingAfter: maximumSyncPayloadDepth) <= maximumSyncPayloadDepth else {
            throw ThemeSyncRejection.tooDeep
        }
        // The decoder refuses a newer schema, an unknown key, a bad color, and a name or author with a
        // control character or past the length cap.
        let theme = try ThemeFileFormat.decode(data)
        guard theme.id == record.id else { throw ThemeSyncRejection.mismatchedIdentifier }
        return (record.schema, theme)
    }
}

private enum ThemeSyncRejection: Error {
    case invalidCategory
    case newerFormat(Int)
    case tooLarge(Int)
    case tooDeep
    case mismatchedIdentifier
}

private enum JSONNesting {
    // Counts container nesting outside strings, and stops once past `limit` so a hostile payload
    // costs no more than that.
    static func depth(of data: Data, stoppingAfter limit: Int) -> Int {
        var depth = 0
        var deepest = 0
        var isInString = false
        var isEscaped = false
        for byte in data {
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    isInString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                isInString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                deepest = max(deepest, depth)
                if deepest > limit { return deepest }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
        }
        return deepest
    }
}
