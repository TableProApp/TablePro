//
//  PanelEnableFilter.swift
//  TablePro
//

import AppKit
import UniformTypeIdentifiers

// Decides which items an open panel offers and checks the pick, for a rule `allowedContentTypes` cannot express:
// a SQLite database saved with no extension, or under someone else's, is told apart only by its bytes. AppKit asks
// `shouldEnable` on the main thread while the panel browses, and opening a file in Desktop, Documents or Downloads
// there waits on the system's consent prompt, so the enable rule goes by name and file type only. The bytes are read
// in `validate`, after the person picked the file, which grants the access.
@MainActor
internal final class PanelEnableFilter: NSObject, NSOpenSavePanelDelegate {
    private let isEnabled: @MainActor (URL) -> Bool
    private let validator: (@MainActor (URL) throws -> Void)?

    // The panel asks again on every scroll.
    private var decisions: [URL: Bool] = [:]

    internal init(
        isEnabled: @escaping @MainActor (URL) -> Bool,
        validate: (@MainActor (URL) throws -> Void)? = nil
    ) {
        self.isEnabled = isEnabled
        self.validator = validate
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if let decided = decisions[url] { return decided }
        let enabled = isEnabled(url) || Self.symlinkTarget(of: url).map(isEnabled) == true || Self.isFinderAlias(url)
        decisions[url] = enabled
        return enabled
    }

    // A dimmed file still comes back from a double-click in list view, so the rule is enforced here too.
    func panel(_ sender: Any, validate url: URL) throws {
        guard let validator else { return }
        do {
            try validator(url)
        } catch {
            guard Self.isFinderAlias(url),
                  let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
            else { throw error }
            try validator(target)
        }
    }

    // A symlink arrives as itself, with neither the target's kind nor its name, so a folder behind one would be dimmed
    // and everything in it stranded. The link's own name is asked first, since it may be the only thing that matches.
    private static func symlinkTarget(of url: URL) -> URL? {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { return nil }
        return try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
    }

    // Resolving a Finder alias reads the alias file, so one stays enabled unresolved: the panel opens one that names a
    // folder, and `validate` checks the file behind one that is picked.
    private static func isFinderAlias(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        return values?.isAliasFile == true && values?.isSymbolicLink != true
    }
}

// What a file's name alone says about its kind, for an enable rule that may not read the file.
internal enum PanelFileName {
    // No extension, one no installed app declares, or a declared type that names no other kind: only the bytes can
    // tell what it holds.
    internal static func leavesKindOpen(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension), type.isDeclared else {
            return true
        }
        if type.conforms(to: .database) { return true }
        return !otherKinds.contains { type.conforms(to: $0) }
    }

    private static let otherKinds: [UTType] = [
        .text, .image, .audiovisualContent, .compositeContent, .font, .presentation, .spreadsheet,
        .executable, .diskImage, .zip, .gzip,
    ]
}
