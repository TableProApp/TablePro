//
//  XAIGrokProvider.swift
//  TablePro
//

import Foundation

final class XAIGrokProvider: ChatTransport {
    static let defaultInstructions = "You are a coding assistant helping with SQL and database tasks."

    private let model: String
    private let tokenStore: XAITokenStore
    private let session: URLSession

    init(
        model: String,
        tokenStore: XAITokenStore = .shared,
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
        ResponsesEventStream.make(
            session: session,
            buildRequest: { [self] in try await buildRequest(turns: turns, options: options, stream: true) },
            refreshOnUnauthorized: { [tokenStore] in _ = try await tokenStore.forceRefresh() }
        )
    }

    func fetchAvailableModels() async throws -> [String] {
        XAI.subscriptionModelIDs
    }

    func testConnection() async throws -> Bool {
        let testModel = model.isEmpty ? XAI.subscriptionModelIDs[0] : model
        let testOptions = ChatTransportOptions(model: testModel)
        let testTurn = ChatTurnWire(role: .user, blocks: [.text("Hi")])
        let request = try await buildRequest(turns: [testTurn], options: testOptions, stream: false)
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
        stream: Bool
    ) async throws -> URLRequest {
        let accessToken = try await tokenStore.validAccessToken()
        guard let url = URL(string: "\(XAI.cliProxyBaseURL)/responses") else {
            throw AIProviderError.invalidEndpoint(XAI.cliProxyBaseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in Self.requestHeaders(accessToken: accessToken, model: options.model) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let body = try Self.requestBody(turns: turns, options: options, stream: stream)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func requestHeaders(accessToken: String, model: String) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(accessToken)",
            XAI.cliTokenAuthHeader: XAI.cliTokenAuthValue,
            XAI.cliClientVersionHeader: XAI.cliClientVersion,
            "User-Agent": XAI.userAgent
        ]
        if !model.isEmpty {
            headers[XAI.cliModelOverrideHeader] = model
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
            body["reasoning"] = ["effort": effort.xaiReasoningEffort]
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
