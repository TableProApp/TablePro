//
//  CopilotDocumentSync.swift
//  TablePro
//

import Foundation
import os

/// Manages LSP document lifecycle for Copilot. Prepends the schema preamble
/// to all document text sent to the server.
@MainActor
final class CopilotDocumentSync {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotDocumentSync")

    private let documentManager = LSPDocumentManager()
    let schemaContext = CopilotSchemaContext()
    private var currentURI: String?
    private var serverSyncedURIs: Set<String> = []
    private var pendingText: [String: String] = [:]
    private var uriMap: [UUID: String] = [:]
    private var nextID = 1
    private var lastKnownGeneration: Int = 0

    func documentURI(for tabID: UUID) -> String {
        if let existing = uriMap[tabID] { return existing }
        let fileURL = CopilotSchemaContext.contextDirectory.appendingPathComponent("query-\(nextID).sql")
        nextID += 1
        let uri = fileURL.absoluteString
        uriMap[tabID] = uri
        return uri
    }

    func resetServerState() {
        serverSyncedURIs.removeAll()
        documentManager.resetAll()
        pendingText.removeAll()
    }

    /// Register document locally. Does NOT send to server.
    func ensureDocumentOpen(tabID: UUID, text: String, languageId: String = "sql") {
        let uri = documentURI(for: tabID)
        let fullText = schemaContext.prependToText(text)
        if !documentManager.isOpen(uri) {
            _ = documentManager.openDocument(uri: uri, languageId: languageId, text: fullText)
        }
        currentURI = uri
    }

    /// Open document at the server with preamble-prepended text
    func didActivateTab(tabID: UUID, text: String, languageId: String = "sql") async {
        let currentGeneration = CopilotService.shared.generation
        if currentGeneration != lastKnownGeneration {
            resetServerState()
            lastKnownGeneration = currentGeneration
        }

        let uri = documentURI(for: tabID)
        let fullText = schemaContext.prependToText(text)
        ensureDocumentOpen(tabID: tabID, text: text, languageId: languageId)

        guard let client = CopilotService.shared.client else { return }
        if !serverSyncedURIs.contains(uri) {
            let item = LSPTextDocumentItem(
                uri: uri,
                languageId: languageId,
                version: documentManager.version(for: uri) ?? 0,
                text: fullText
            )
            await client.didOpenDocument(item)
            serverSyncedURIs.insert(uri)

            if let pending = pendingText.removeValue(forKey: uri) {
                let pendingFull = schemaContext.prependToText(pending)
                if let (versioned, changes) = documentManager.changeDocument(uri: uri, newText: pendingFull) {
                    await client.didChangeDocument(uri: versioned.uri, version: versioned.version, changes: changes)
                }
            }
        }
        await client.didFocusDocument(uri: uri)
    }

    /// Send text change with preamble prepended
    func didChangeText(tabID: UUID, newText: String) async {
        let currentGeneration = CopilotService.shared.generation
        if currentGeneration != lastKnownGeneration {
            resetServerState()
            lastKnownGeneration = currentGeneration
        }

        let uri = documentURI(for: tabID)
        guard serverSyncedURIs.contains(uri) else {
            pendingText[uri] = newText
            return
        }
        let fullText = schemaContext.prependToText(newText)
        guard let client = CopilotService.shared.client else { return }
        guard let (versioned, changes) = documentManager.changeDocument(uri: uri, newText: fullText) else { return }
        await client.didChangeDocument(uri: versioned.uri, version: versioned.version, changes: changes)
    }

    func didCloseTab(tabID: UUID) async {
        let uri = documentURI(for: tabID)
        guard let client = CopilotService.shared.client else { return }
        guard let docId = documentManager.closeDocument(uri: uri) else { return }
        await client.didCloseDocument(uri: docId.uri)
        serverSyncedURIs.remove(uri)
        uriMap.removeValue(forKey: tabID)
        if currentURI == uri { currentURI = nil }
    }

    func currentDocumentInfo() -> (uri: String, version: Int)? {
        guard let uri = currentURI else { return nil }
        guard serverSyncedURIs.contains(uri) else { return nil }
        guard let version = documentManager.version(for: uri) else { return nil }
        return (uri, version)
    }
}
