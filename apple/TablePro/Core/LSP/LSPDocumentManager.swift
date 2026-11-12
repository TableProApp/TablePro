//
//  LSPDocumentManager.swift
//  TablePro
//

import Foundation

@MainActor
final class LSPDocumentManager {
    private var versions: [String: Int] = [:]

    func openDocument(uri: String, languageId: String, text: String) -> LSPTextDocumentItem {
        versions[uri] = 0
        return LSPTextDocumentItem(uri: uri, languageId: languageId, version: 0, text: text)
    }

    func changeDocument(uri: String, changes: [LSPTextDocumentContentChangeEvent]) -> LSPDidChangeParams? {
        guard let version = versions[uri] else { return nil }
        versions[uri] = version + 1
        return LSPDidChangeParams(
            textDocument: LSPVersionedTextDocumentIdentifier(uri: uri, version: version + 1),
            contentChanges: changes
        )
    }

    func closeDocument(uri: String) -> LSPTextDocumentIdentifier? {
        guard versions.removeValue(forKey: uri) != nil else { return nil }
        return LSPTextDocumentIdentifier(uri: uri)
    }

    func version(for uri: String) -> Int? {
        versions[uri]
    }
}
