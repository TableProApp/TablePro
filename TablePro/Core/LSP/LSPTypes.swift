//
//  LSPTypes.swift
//  TablePro
//

import Foundation

// MARK: - LSP Data Types

struct LSPPosition: Codable, Sendable, Equatable {
    let line: Int
    let character: Int
}

struct LSPRange: Codable, Sendable, Equatable {
    let start: LSPPosition
    let end: LSPPosition
}

struct LSPTextDocumentIdentifier: Codable, Sendable, Equatable {
    let uri: String
}

struct LSPTextDocumentItem: Codable, Sendable, Equatable {
    let uri: String
    let languageId: String
    let version: Int
    let text: String
}

struct LSPVersionedTextDocumentIdentifier: Codable, Sendable, Equatable {
    let uri: String
    let version: Int
}

struct LSPTextDocumentContentChangeEvent: Codable, Sendable, Equatable {
    let text: String
}

struct LSPInlineCompletionItem: Codable, Sendable, Equatable {
    let insertText: String
    let range: LSPRange?
    let command: LSPCommand?
}

struct LSPInlineCompletionList: Codable, Sendable, Equatable {
    let items: [LSPInlineCompletionItem]
}

struct LSPCommand: Codable, Sendable, Equatable {
    let title: String
    let command: String
    let arguments: [AnyCodable]?
}

struct LSPFormattingOptions: Codable, Sendable, Equatable {
    let tabSize: Int
    let insertSpaces: Bool
}

struct LSPInlineCompletionContext: Codable, Sendable, Equatable {
    let triggerKind: Int
}

struct LSPInlineCompletionParams: Codable, Sendable, Equatable {
    let textDocument: LSPVersionedTextDocumentIdentifier
    let position: LSPPosition
    let context: LSPInlineCompletionContext
    let formattingOptions: LSPFormattingOptions
}

struct LSPDidShowCompletionParams: Codable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let items: [LSPInlineCompletionItem]
}

struct LSPClientInfo: Codable, Sendable, Equatable {
    let name: String
    let version: String
}

struct LSPWorkspaceFolder: Codable, Sendable {
    let uri: String
    let name: String
}

struct LSPInitializeParams: Codable, Sendable {
    let processId: Int
    let capabilities: LSPClientCapabilities
    let initializationOptions: LSPInitializationOptions
    let workspaceFolders: [LSPWorkspaceFolder]?
}

struct LSPClientCapabilities: Codable, Sendable {
    let general: LSPGeneralCapabilities?
}

struct LSPGeneralCapabilities: Codable, Sendable {
    let positionEncodings: [String]?
}

struct LSPInitializationOptions: Codable, Sendable {
    let editorInfo: LSPClientInfo
    let editorPluginInfo: LSPClientInfo?
}

struct LSPInitializeResult: Sendable {
    let rawData: Data
}

// MARK: - LSP Notification/Request Param Types

struct EmptyLSPParams: Codable, Sendable {}

struct LSPDidOpenParams: Codable, Sendable {
    let textDocument: LSPTextDocumentItem
}

struct LSPDidChangeParams: Codable, Sendable {
    let textDocument: LSPVersionedTextDocumentIdentifier
    let contentChanges: [LSPTextDocumentContentChangeEvent]
}

struct LSPDocumentParams: Codable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
}

struct LSPExecuteCommandParams: Codable, Sendable {
    let command: String
    let arguments: [AnyCodable]?
}

struct LSPConfigurationParams: Codable, Sendable {
    let settings: [String: AnyCodable]
}

// MARK: - LSP JSON-RPC Types

struct LSPJSONRPCRequest<P: Encodable>: Encodable {
    let jsonrpc: String = "2.0"
    let id: Int
    let method: String
    let params: P?
}

struct LSPJSONRPCNotification<P: Encodable>: Encodable {
    let jsonrpc: String = "2.0"
    let method: String
    let params: P?
}

struct LSPJSONRPCResponse<R: Decodable>: Decodable {
    let id: Int?
    let result: R?
    let error: LSPJSONRPCError?
}

struct LSPJSONRPCError: Decodable, Sendable {
    let code: Int
    let message: String
}

// MARK: - Copilot Conversation Types

struct CopilotConversationTurn: Codable, Sendable {
    let request: String
    let response: String
    let turnId: String
}

struct CopilotConversationCapabilities: Codable, Sendable {
    let skills: [String]
    let allSkills: Bool
}

struct CopilotConversationCreateParams: Codable, Sendable {
    let workDoneToken: String
    let turns: [CopilotConversationTurn]
    let capabilities: CopilotConversationCapabilities
    let source: String
    let model: String?
    let workspaceFolders: [LSPWorkspaceFolder]?
    let chatMode: String?
    let customChatModeId: String?
    let needToolCallConfirmation: Bool?

    init(
        workDoneToken: String,
        turns: [CopilotConversationTurn],
        capabilities: CopilotConversationCapabilities,
        source: String,
        model: String?,
        workspaceFolders: [LSPWorkspaceFolder]?,
        chatMode: String? = nil,
        customChatModeId: String? = nil,
        needToolCallConfirmation: Bool? = nil
    ) {
        self.workDoneToken = workDoneToken
        self.turns = turns
        self.capabilities = capabilities
        self.source = source
        self.model = model
        self.workspaceFolders = workspaceFolders
        self.chatMode = chatMode
        self.customChatModeId = customChatModeId
        self.needToolCallConfirmation = needToolCallConfirmation
    }
}

struct CopilotConversationCreateResult: Codable, Sendable {
    let conversationId: String
    let turnId: String
}

struct CopilotConversationTurnParams: Codable, Sendable {
    let workDoneToken: String
    let conversationId: String
    let message: String
    let source: String
    let model: String?
    let workspaceFolders: [LSPWorkspaceFolder]?
}

struct CopilotConversationTurnResult: Codable, Sendable {
    let turnId: String
}

struct CopilotConversationDestroyParams: Codable, Sendable {
    let conversationId: String
    let options: [String: AnyCodable]?
}

struct CopilotConversationTurnDeleteParams: Codable, Sendable {
    let conversationId: String
    let turnId: String
    let source: String
}

struct CopilotProgressParams: Codable, Sendable {
    let token: String
    let value: CopilotProgressValue
}

struct CopilotProgressValue: Codable, Sendable {
    let kind: String
    let title: String?
    let reply: String?
    let result: CopilotProgressResult?
}

struct CopilotProgressResult: Codable, Sendable {
    let followUp: String?
}

struct CopilotModel: Codable, Sendable {
    let id: String
    let modelFamily: String?
    let modelName: String?
    let scopes: [String]?
    let isChatDefault: Bool?
    let preview: Bool?
}

// MARK: - AnyCodable

/// Type-erased Codable wrapper for heterogeneous JSON values
struct AnyCodable: Codable, Sendable, Equatable {
    let value: AnyCodableValue

    init(_ value: Any?) {
        if let value {
            self.value = AnyCodableValue(value)
        } else {
            self.value = .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            value = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            value = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            value = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            value = .string(stringVal)
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            value = .array(arrayVal)
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            value = .dictionary(dictVal)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported AnyCodable value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null:
            try container.encodeNil()
        case .bool(let boolVal):
            try container.encode(boolVal)
        case .int(let intVal):
            try container.encode(intVal)
        case .double(let doubleVal):
            try container.encode(doubleVal)
        case .string(let stringVal):
            try container.encode(stringVal)
        case .array(let arrayVal):
            try container.encode(arrayVal)
        case .dictionary(let dictVal):
            try container.encode(dictVal)
        }
    }
}

enum AnyCodableValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case dictionary([String: AnyCodable])

    init(_ value: Any) {
        switch value {
        case let boolVal as Bool:
            self = .bool(boolVal)
        case let intVal as Int:
            self = .int(intVal)
        case let doubleVal as Double:
            self = .double(doubleVal)
        case let stringVal as String:
            self = .string(stringVal)
        case let arrayVal as [Any]:
            self = .array(arrayVal.map { AnyCodable($0) })
        case let dictVal as [String: Any]:
            self = .dictionary(dictVal.mapValues { AnyCodable($0) })
        default:
            self = .null
        }
    }
}

// MARK: - Copilot tool calling

struct CopilotLanguageModelToolInformation: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: JsonValue?
}

struct CopilotRegisterToolsParams: Codable, Sendable {
    let tools: [CopilotLanguageModelToolInformation]
}

struct CopilotInvokeClientToolParams: Codable, Sendable {
    let name: String
    let input: JsonValue?
    let conversationId: String
    let turnId: String
}

enum CopilotToolInvocationStatus: String, Codable, Sendable {
    case success
    case error
    case cancelled
}

struct CopilotLanguageModelToolResultContent: Codable, Sendable {
    let value: JsonValue
}

struct CopilotLanguageModelToolResult: Codable, Sendable {
    let status: CopilotToolInvocationStatus
    let content: [CopilotLanguageModelToolResultContent]
}
