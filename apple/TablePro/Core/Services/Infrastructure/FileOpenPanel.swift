//
//  FileOpenPanel.swift
//  TablePro
//

import AppKit

// The panel behind File > Open File…, offering everything TablePro can open rather than SQL alone.
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

    // A plain folder stays enabled so the panel can be navigated; a package such as `.tableplugin` is classified
    // like a file. The name settles most of a folder, and the bytes are read only when they are already here.
    private static func isOpenable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return true }
        if case .some(.success) = URLClassifier.classifyByName(url) { return true }
        return DatabaseFileClassifier.classify(url, access: .withoutWaiting) != nil
    }
}
