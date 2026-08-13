//
//  FileDropDestination.swift
//  TablePro
//

import AppKit

/// Registered on the window rather than its content view, so a text view or chat composer inside
/// keeps first claim on a drag and only what they refuse reaches here.
@MainActor
internal enum FileDropDestination {
    internal static func register(on window: NSWindow) {
        window.registerForDraggedTypes([.fileURL])
    }

    internal static func acceptedURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return []
        }
        return urls.filter { isOpenable($0) }
    }

    /// A file TablePro cannot open must refuse the drag outright. Accepting it and then failing
    /// silently is worse than showing no drop feedback at all.
    internal static func isOpenable(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard case .some(.success) = URLClassifier.classify(url) else { return false }
        return true
    }

    internal static func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        AppLaunchCoordinator.shared.handleOpenURLs(urls)
    }
}
