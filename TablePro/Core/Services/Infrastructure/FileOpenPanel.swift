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

        let filter = PanelEnableFilter(isEnabled: isOpenable)
        panel.delegate = filter
        let response = await panel.begin()
        withExtendedLifetime(filter) {}

        guard response == .OK else { return nil }
        return panel.urls
    }

    /// A plain folder stays enabled so the panel can be navigated. A package is a file as far as
    /// the user is concerned, and `.tableplugin` is one, so it is classified like any other.
    ///
    /// The name is asked first and settles most of a folder without touching its contents.
    private static func isOpenable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return true }
        if case .some(.success) = URLClassifier.classifyByName(url) { return true }
        return PanelEnableFilter.isQuickToRead(url) && DatabaseFileClassifier.classify(url) != nil
    }
}
