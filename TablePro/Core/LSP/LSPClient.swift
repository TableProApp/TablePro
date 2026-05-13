//
//  LSPClient.swift
//  TablePro
//

import Foundation
import os

actor LSPClient {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LSPClient")

    private let transport: LSPTransport

    init(transport: LSPTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    func initialize(
        clientInfo: LSPClientInfo,
        editorPluginInfo: LSPClientInfo?,
        processId: Int?,
        workspaceFolders: [LSPWorkspaceFolder]? = nil
    ) async throws -> LSPInitializeResult {
        let params = LSPInitializeParams(
            processId: processId ?? Int(ProcessInfo.processInfo.processIdentifier),
            capabilities: LSPClientCapabilities(
                general: LSPGeneralCapabilities(positionEncodings: ["utf-16"])
            ),
            initializationOptions: LSPInitializationOptions(
                editorInfo: clientInfo,
                editorPluginInfo: editorPluginInfo
            ),
            workspaceFolders: workspaceFolders
        )

        let data = try await transport.sendRequest(method: "initialize", params: params)
        Self.logger.info("LSP initialized")
        return LSPInitializeResult(rawData: data)
    }

    func initialized() async {
        do {
            try await transport.sendNotification(method: "initialized", params: EmptyLSPParams())
        } catch {
            Self.logger.warning("Failed to send initialized: \(error.localizedDescription)")
        }
    }

    func shutdown() async throws {
        _ = try await transport.sendRequest(method: "shutdown", params: EmptyLSPParams())
        Self.logger.info("LSP shutdown complete")
    }

    func exit() async {
        do {
            try await transport.sendNotification(method: "exit", params: EmptyLSPParams())
        } catch {
            Self.logger.debug("Failed to send exit: \(error.localizedDescription)")
        }
    }

    // MARK: - Document Sync

    func didOpenDocument(_ item: LSPTextDocumentItem) async {
        let params = LSPDidOpenParams(textDocument: item)
        do {
            try await transport.sendNotification(method: "textDocument/didOpen", params: params)
        } catch {
            Self.logger.debug("Failed to send didOpen: \(error.localizedDescription)")
        }
    }

    func didChangeDocument(
        uri: String,
        version: Int,
        changes: [LSPTextDocumentContentChangeEvent]
    ) async {
        let params = LSPDidChangeParams(
            textDocument: LSPVersionedTextDocumentIdentifier(uri: uri, version: version),
            contentChanges: changes
        )
        do {
            try await transport.sendNotification(method: "textDocument/didChange", params: params)
        } catch {
            Self.logger.debug("Failed to send didChange: \(error.localizedDescription)")
        }
    }

    func didCloseDocument(uri: String) async {
        let params = LSPDocumentParams(textDocument: LSPTextDocumentIdentifier(uri: uri))
        do {
            try await transport.sendNotification(method: "textDocument/didClose", params: params)
        } catch {
            Self.logger.debug("Failed to send didClose: \(error.localizedDescription)")
        }
    }

    func didFocusDocument(uri: String) async {
        let params = LSPDocumentParams(textDocument: LSPTextDocumentIdentifier(uri: uri))
        do {
            try await transport.sendNotification(method: "textDocument/didFocus", params: params)
        } catch {
            Self.logger.debug("Failed to send didFocus: \(error.localizedDescription)")
        }
    }

    // MARK: - Inline Completions

    func inlineCompletion(params: LSPInlineCompletionParams) async throws -> LSPInlineCompletionList {
        let data = try await transport.sendRequest(method: "textDocument/inlineCompletion", params: params)

        if let list = try? JSONDecoder().decode(LSPInlineCompletionList.self, from: data) {
            return list
        }
        if let items = try? JSONDecoder().decode([LSPInlineCompletionItem].self, from: data) {
            return LSPInlineCompletionList(items: items)
        }

        return LSPInlineCompletionList(items: [])
    }

    // MARK: - Commands

    func executeCommand(command: String, arguments: [AnyCodable]?) async throws {
        let params = LSPExecuteCommandParams(command: command, arguments: arguments)
        _ = try await transport.sendRequest(method: "workspace/executeCommand", params: params)
    }

    // MARK: - Conversation (Chat)

    func conversationCreate(params: CopilotConversationCreateParams) async throws -> CopilotConversationCreateResult {
        let data = try await transport.sendRequest(method: "conversation/create", params: params)
        return try JSONDecoder().decode(CopilotConversationCreateResult.self, from: data)
    }

    func conversationTurn(params: CopilotConversationTurnParams) async throws -> CopilotConversationTurnResult {
        let data = try await transport.sendRequest(method: "conversation/turn", params: params)
        return try JSONDecoder().decode(CopilotConversationTurnResult.self, from: data)
    }

    func conversationDestroy(conversationId: String) async throws {
        let params = CopilotConversationDestroyParams(conversationId: conversationId, options: nil)
        _ = try await transport.sendRequest(method: "conversation/destroy", params: params)
    }

    func conversationTurnDelete(conversationId: String, turnId: String) async throws {
        let params = CopilotConversationTurnDeleteParams(
            conversationId: conversationId, turnId: turnId, source: "panel"
        )
        _ = try await transport.sendRequest(method: "conversation/turnDelete", params: params)
    }

    // MARK: - Copilot Models

    func fetchCopilotModels() async throws -> [CopilotModel] {
        let data = try await transport.sendRequest(method: "copilot/models", params: EmptyLSPParams())
        if let models = try? JSONDecoder().decode([CopilotModel].self, from: data) {
            return models
        }
        return []
    }

    // MARK: - Configuration

    func didChangeConfiguration(settings: [String: AnyCodable]) async {
        let params = LSPConfigurationParams(settings: settings)
        do {
            try await transport.sendNotification(method: "workspace/didChangeConfiguration", params: params)
        } catch {
            Self.logger.debug("Failed to send didChangeConfiguration: \(error.localizedDescription)")
        }
    }

    // MARK: - Cancel Request

    func cancelRequest(id: Int) async {
        await transport.cancelRequest(id: id)
    }

    // MARK: - Notifications from Server

    func onNotification(method: String, handler: @escaping @Sendable (Data) -> Void) async {
        await transport.onNotification(method: method, handler: handler)
    }

    func onRequest(method: String, handler: @escaping @Sendable (Data) -> Any?) async {
        await transport.onRequest(method: method, handler: handler)
    }

    func onDeferredRequest(method: String, handler: @escaping @Sendable (Data, Int) -> Void) async {
        await transport.onDeferredRequest(method: method, handler: handler)
    }

    // MARK: - Copilot tool calling

    func registerTools(_ params: CopilotRegisterToolsParams) async throws {
        _ = try await transport.sendRequest(method: "conversation/registerTools", params: params)
    }

    func sendInvokeClientToolResponse(id: Int, result: CopilotLanguageModelToolResult) async throws {
        try await transport.sendDeferredArrayResponse(id: id, result: result)
    }
}
