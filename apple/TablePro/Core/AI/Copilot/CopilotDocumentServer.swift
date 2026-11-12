import Foundation

@MainActor
protocol CopilotDocumentServer {
    var generation: Int { get }
    var hasClient: Bool { get }
    func didOpen(_ document: LSPTextDocumentItem) async
    func didChange(_ change: LSPDidChangeParams) async
    func didFocus(uri: String) async
    func didClose(uri: String) async
}

@MainActor
struct LiveCopilotDocumentServer: CopilotDocumentServer {
    var generation: Int { CopilotService.shared.generation }

    var hasClient: Bool { CopilotService.shared.client != nil }

    func didOpen(_ document: LSPTextDocumentItem) async {
        await CopilotService.shared.client?.didOpenDocument(document)
    }

    func didChange(_ change: LSPDidChangeParams) async {
        await CopilotService.shared.client?.didChangeDocument(
            uri: change.textDocument.uri,
            version: change.textDocument.version,
            changes: change.contentChanges
        )
    }

    func didFocus(uri: String) async {
        await CopilotService.shared.client?.didFocusDocument(uri: uri)
    }

    func didClose(uri: String) async {
        await CopilotService.shared.client?.didCloseDocument(uri: uri)
    }
}
