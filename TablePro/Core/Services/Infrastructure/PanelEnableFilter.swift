//
//  PanelEnableFilter.swift
//  TablePro
//

import AppKit

/// Decides which items an open panel lets someone choose, for a rule `allowedContentTypes` cannot
/// express because it matches names only: a SQLite database saved with no extension, or under
/// someone else's, is reachable only by reading its bytes.
@MainActor
internal final class PanelEnableFilter: NSObject, NSOpenSavePanelDelegate {
    private let isEnabled: @MainActor (URL) -> Bool

    /// The panel asks again on every scroll, and a rule may read the head of the file.
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

    /// The panel hands over a symlink or a Finder alias as itself, and neither reads as a folder or
    /// has the target's bytes, so a rule that keeps folders enabled would dim a linked one and strand
    /// everything behind it. The link's own name is still asked first, since it may be the only
    /// thing that matches. An alias on a volume that is not mounted stays unresolved.
    /// Whether reading the head of this file is quick enough to do while the panel waits. This runs on
    /// the main actor, and a file on a network volume or an iCloud file not yet downloaded takes as
    /// long as that volume does, so the whole app would wait with it. Such a file is matched by
    /// name only; its path can still be typed.
    nonisolated internal static func isQuickToRead(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsLocal == true else {
            return false
        }
        if let status = values.ubiquitousItemDownloadingStatus, status != .current { return false }
        return true
    }

    private static func linkTarget(of url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        guard values?.isSymbolicLink == true || values?.isAliasFile == true else { return nil }
        return try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
    }
}
