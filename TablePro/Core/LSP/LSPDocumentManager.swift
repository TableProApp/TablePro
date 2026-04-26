//
//  LSPDocumentManager.swift
//  TablePro
//

import Foundation

@MainActor
final class LSPDocumentManager {
    struct DocumentState {
        var uri: String
        var version: Int
        var languageId: String
    }

    private var documents: [String: DocumentState] = [:]

    func openDocument(uri: String, languageId: String, text: String) -> LSPTextDocumentItem {
        let state = DocumentState(uri: uri, version: 0, languageId: languageId)
        documents[uri] = state
        return LSPTextDocumentItem(uri: uri, languageId: languageId, version: 0, text: text)
    }

    func changeDocument(
        uri: String,
        newText: String
    ) -> (versioned: LSPVersionedTextDocumentIdentifier, changes: [LSPTextDocumentContentChangeEvent])? {
        guard var state = documents[uri] else { return nil }
        state.version += 1
        documents[uri] = state
        return (
            versioned: LSPVersionedTextDocumentIdentifier(uri: uri, version: state.version),
            changes: [LSPTextDocumentContentChangeEvent(text: newText)]
        )
    }

    func closeDocument(uri: String) -> LSPTextDocumentIdentifier? {
        guard documents.removeValue(forKey: uri) != nil else { return nil }
        return LSPTextDocumentIdentifier(uri: uri)
    }

    func version(for uri: String) -> Int? {
        documents[uri]?.version
    }

    func isOpen(_ uri: String) -> Bool {
        documents[uri] != nil
    }

    func resetAll() {
        documents.removeAll()
    }
}
