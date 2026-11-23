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

        let filter = PanelEnableFilter(isEnabled: isOpenable, validate: validate)
        panel.delegate = filter
        let response = await panel.begin()
        withExtendedLifetime(filter) {}

        guard response == .OK else { return nil }
        return panel.urls
    }

    // A plain folder stays enabled so the panel can be navigated; a package such as `.tableplugin` is classified
    // like a file. The name settles most of a folder, and a file whose name says nothing is left for `validate`.
    internal static func isOpenable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileResourceTypeKey])
        if values?.isDirectory == true, values?.isPackage != true { return true }
        if case .some(.success) = URLClassifier.classifyByName(url) { return true }
        return values?.fileResourceType == .regular && PanelFileName.leavesKindOpen(url)
    }

    // A file whose bytes are not on this Mac yet is let through; opening it decides, as a drop or a Finder open does.
    internal static func validate(_ url: URL) throws {
        if case .some(.success) = URLClassifier.classifyByName(url) { return }
        if DatabaseFileClassifier.classify(url, access: .withoutWaiting) != nil { return }
        guard DatabaseFileClassifier.isReadableWithoutWaiting(url) else { return }
        throw FileOpenPanelError.unsupported(fileName: url.lastPathComponent)
    }
}

private enum FileOpenPanelError: LocalizedError {
    case unsupported(fileName: String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let fileName):
            return String(format: String(localized: "TablePro can’t open “%@”."), fileName)
        }
    }

    var recoverySuggestion: String? {
        String(localized: "TablePro opens database files, SQL files, data files, connection shares and plugins.")
    }
}
