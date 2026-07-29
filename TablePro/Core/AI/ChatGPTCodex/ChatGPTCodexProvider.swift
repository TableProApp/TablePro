//
//  ChatGPTCodexProvider.swift
//  TablePro
//

import Foundation

final class ChatGPTCodexProvider: ChatTransport {
    static let defaultInstructions = "You are a coding assistant helping with SQL and database tasks."

    private let model: String
    private let tokenStore: ChatGPTCodexTokenStore
    private let session: URLSession

    init(
        model: String,
        tokenStore: ChatGPTCodexTokenStore = .shared,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokenStore = tokenStore
        self.session = session
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let sessionID = UUID().uuidString
        return ResponsesEventStream.make(
            session: session,
            treatForbiddenAsAuthFailure: true,
            buildRequest: { [self] in
                try await buildRequest(turns: turns, options: options, stream: true, sessionID: sessionID)
            },
            refreshOnUnauthorized: { [tokenStore] in _ = try await tokenStore.forceRefresh() }
        )
    }

    func fetchAvailableModels() async throws -> [String] {
        ChatGPTCodex.curatedModelIDs
    }

    func testConnection() async throws -> Bool {
        let testModel = model.isEmpty ? ChatGPTCodex.curatedModelIDs[0] : model
        let testOptions = ChatTransportOptions(model: testModel)
        let testTurn = ChatTurnWire(role: .user, blocks: [.text("Hi")])
        let request = try await buildRequest(
            turns: [testTurn],
            options: testOptions,
            stream: false,
            sessionID: UUID().uuidString
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        if httpResponse.statusCode == 200 || httpResponse.statusCode == 400 {
            return true
        }
        if httpResponse.statusCode == 401 {
            throw AIProviderError.authenticationFailed("")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw AIProviderError.mapHTTPError(statusCode: httpResponse.statusCode, body: body)
    }

    private func buildRequest(
        turns: [ChatTurnWire],
        options: ChatTransportOptions,
        stream: Bool,
        sessionID: String
    ) async throws -> URLRequest {
        let accessToken = try await tokenStore.validAccessToken()
        let accountID = await tokenStore.accountID() ?? ""
        guard let url = URL(string: "\(ChatGPTCodex.backendBaseURL)/responses") else {
            throw AIProviderError.invalidEndpoint(ChatGPTCodex.backendBaseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in Self.requestHeaders(accessToken: accessToken, accountID: accountID, sessionID: sessionID) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let body = try Self.requestBody(turns: turns, options: options, stream: stream)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func requestHeaders(accessToken: String, accountID: String, sessionID: String) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(accessToken)",
            "session-id": sessionID,
            "originator": ChatGPTCodex.originator,
            "User-Agent": ChatGPTCodex.userAgent
        ]
        if !accountID.isEmpty {
            headers["ChatGPT-Account-ID"] = accountID
        }
        return headers
    }

    static func requestBody(
        turns: [ChatTurnWire],
        options: ChatTransportOptions,
        stream: Bool
    ) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": options.model,
            "input": try OpenAIResponsesProvider.encodeInput(turns: turns),
            "store": false,
            "stream": stream,
            "instructions": instructions(for: options)
        ]

        if let effort = options.reasoningEffort {
            body["reasoning"] = ["effort": effort.openAIWireValue, "summary": "auto"]
            body["include"] = ["reasoning.encrypted_content"]
        }

        if !options.tools.isEmpty {
            body["tools"] = try options.tools.map(OpenAIResponsesProvider.encodeToolSpec(_:))
        }

        return body
    }

    private static func instructions(for options: ChatTransportOptions) -> String {
        if let prompt = options.systemPrompt, !prompt.isEmpty {
            return prompt
        }
        return defaultInstructions
    }
}
