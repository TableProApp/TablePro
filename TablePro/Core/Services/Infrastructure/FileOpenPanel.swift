//
//  FileOpenPanel.swift
//  TablePro
//

import AppKit

/// The panel behind File > Open File…, offering everything TablePro can open rather than SQL alone.
@MainActor
internal enum FileOpenPanel {
    internal static func present() async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Select files to open")

        let filter = OpenableFileFilter()
        panel.delegate = filter
        let response = await panel.begin()
        withExtendedLifetime(filter) {}

        guard response == .OK else { return nil }
        return panel.urls
    }
}

/// `allowedContentTypes` can only match a name, so it disables the files this panel exists to
/// reach: a SQLite database saved with no extension, or under someone else's.
@MainActor
private final class OpenableFileFilter: NSObject, NSOpenSavePanelDelegate {
    /// The panel asks again on every scroll, and deciding costs a read of the file's head.
    private var decisions: [URL: Bool] = [:]

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if let decided = decisions[url] { return decided }
        let enabled = isOpenable(url)
        decisions[url] = enabled
        return enabled
    }

    /// A plain folder stays enabled so the panel can be navigated. A package is a file as far as
    /// the user is concerned, and `.tableplugin` is one, so it is classified like any other.
    ///
    /// The name is asked first and settles most of a folder without touching its contents. This
    /// delegate runs on the main actor, and reading the head of a file on an unavailable mount or
    /// an iCloud placeholder takes as long as that mount does, whatever the sixteen bytes suggest.
    private func isOpenable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return true }
        if case .some(.success) = URLClassifier.classifyByName(url) { return true }
        return DatabaseFileClassifier.classify(url) != nil
    }
}
