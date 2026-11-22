//
//  PanelEnableFilter.swift
//  TablePro
//

import AppKit

// Decides which items an open panel lets someone choose, for a rule `allowedContentTypes` cannot express because
// it matches names only: a SQLite database saved with no extension, or under someone else's, is reachable only by
// reading its bytes. AppKit asks on the main thread while the panel browses, so a rule reads a file only through
// `DatabaseFileClassifier.Access.withoutWaiting`.
@MainActor
internal final class PanelEnableFilter: NSObject, NSOpenSavePanelDelegate {
    private let isEnabled: @MainActor (URL) -> Bool

    // The panel asks again on every scroll, and a rule may read the head of the file.
    private var decisions: [URL: Bool] = [:]

    internal init(isEnabled: @escaping @MainActor (URL) -> Bool) {
        self.isEnabled = isEnabled
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if let decided = decisions[url] { return decided }
        let enabled = isEnabled(url) || Self.linkTarget(of: url).map(isEnabled) == true
        decisions[url] = enabled
        return enabled
    }

    // A symlink or Finder alias arrives as itself, with neither the target's kind nor its bytes, so a folder behind
    // one would be dimmed and everything in it stranded. The link's own name is asked first, since it may be the
    // only thing that matches. An alias is a file of its own that resolving reads, so one that is not here yet is
    // left unresolved, and so is one on a volume that is not mounted.
    private static func linkTarget(of url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        if values?.isSymbolicLink == true {
            return try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
        }
        guard values?.isAliasFile == true, DatabaseFileClassifier.isReadableWithoutWaiting(url) else { return nil }
        return DatabaseFileClassifier.withoutMaterializing {
            try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
        }
    }
}
