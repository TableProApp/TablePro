//
//  DatabaseFilePanel.swift
//  TablePro
//

import AppKit
import UniformTypeIdentifiers

/// The two panels behind a database file field: Browse… picks a file that exists, New… names one
/// that does not.
///
/// An open panel has no name field, so it cannot reach a file that is not there yet. A driver that
/// creates its file on connect needs the save panel too, and the save panel only records the path:
/// the file is made by the driver at connect, so confirming Replace on an existing database leaves
/// it as it was.
@MainActor
internal enum DatabaseFilePanel {
    internal static func chooseExisting(
        for type: DatabaseType,
        currentPath: String,
        in window: NSWindow?
    ) async -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = DatabaseFileLocation(path: currentPath).existingFolder

        let rule = DatabaseFileBrowseRule(type: type, extensions: PluginManager.shared.fileExtensions(for: type))
        let filter = PanelEnableFilter(isEnabled: rule.isEnabled)
        panel.delegate = filter
        let response = await present(panel, in: window)
        withExtendedLifetime(filter) {}

        guard response == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }

    internal static func nameNew(
        extensions: [String],
        currentPath: String,
        in window: NSWindow?
    ) async -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = DatabaseFileTypes.contentTypes(forExtensions: extensions)
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        /// Tags are applied by whoever writes the file, and nothing writes it until the driver
        /// connects, so tags typed here would be dropped.
        panel.showsTagField = false
        panel.prompt = String(localized: "Create")
        /// The system's Replace alert says the file will be overwritten, and it will not be: the path is
        /// only recorded, so the message says what happens before the alert can say otherwise.
        panel.message = String(
            localized: "Choose a name and location for the new database. TablePro creates it when you connect, and opens a file that already exists as it is."
        )

        let location = DatabaseFileLocation(path: currentPath)
        panel.directoryURL = location.existingFolder
        panel.nameFieldStringValue = location.suggestedNewFileName(preferredExtension: extensions.first)

        guard await present(panel, in: window) == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }

    private static func present(_ panel: NSSavePanel, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return await panel.begin() }
        return await panel.presentAsSheet(for: window)
    }
}

/// Which items Browse… lets someone choose for a database file field.
///
/// Matched by extension first, which settles most of a folder without reading anything, then by the
/// file's own bytes when they are on this Mac, so a SQLite database saved with no extension or under
/// another app's (a browser's `History`, a `.gpkg`) can still be picked. A type that declares no
/// extensions keeps every file, because there is nothing to match against.
internal struct DatabaseFileBrowseRule: Sendable {
    private let type: DatabaseType
    private let extensions: Set<String>
    private let classify: @Sendable (URL) -> DatabaseType?

    internal init(
        type: DatabaseType,
        extensions: [String],
        classify: @escaping @Sendable (URL) -> DatabaseType? = DatabaseFileBrowseRule.classifyIfQuick
    ) {
        self.type = type
        self.extensions = Set(extensions.map(Self.normalized).filter { !$0.isEmpty })
        self.classify = classify
    }

    /// A plain folder stays enabled so the panel can be navigated. A package is a file to the user,
    /// so it is matched like one.
    internal func isEnabled(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return true }
        guard !extensions.isEmpty else { return true }
        if extensions.contains(Self.normalized(url.pathExtension)) { return true }
        return classify(url) == type
    }

    internal static func classifyIfQuick(_ url: URL) -> DatabaseType? {
        guard PanelEnableFilter.isQuickToRead(url) else { return nil }
        return DatabaseFileClassifier.classify(url)
    }

    private static func normalized(_ fileExtension: String) -> String {
        fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
    }
}

/// What the path already in a database file field says about where a panel should open.
internal struct DatabaseFileLocation {
    private let fileURL: URL?
    private let isFolder: Bool
    private let fileManager: FileManager

    /// Only an absolute path, after `~` is expanded, names a place. A relative one would resolve
    /// against the app's working directory, which the user never chose.
    internal init(path: String, fileManager: FileManager = .default) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        let named = expanded.hasPrefix("/") && expanded != "/"
        var isDirectory: ObjCBool = false
        let exists = named && fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory)
        self.isFolder = exists && isDirectory.boolValue
        self.fileURL = named ? URL(fileURLWithPath: expanded, isDirectory: isFolder) : nil
        self.fileManager = fileManager
    }

    /// The folder the path names, or the one holding the file it names.
    internal var existingFolder: URL? {
        guard let fileURL else { return nil }
        if isFolder { return fileURL }
        let folder = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return folder
    }

    /// The name already typed, when nothing exists there yet, so New… confirms what the field says.
    /// Otherwise "Untitled", which is what a new document is called until someone names it.
    internal func suggestedNewFileName(preferredExtension: String?) -> String {
        if let fileURL, !isFolder, existingFolder != nil, !fileManager.fileExists(atPath: fileURL.path) {
            return fileURL.lastPathComponent
        }
        let untitled = String(localized: "Untitled")
        let fileExtension = preferredExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) ?? ""
        return fileExtension.isEmpty ? untitled : "\(untitled).\(fileExtension)"
    }
}
