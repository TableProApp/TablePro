//
//  ChatGPTCodexProvider.swift
//  TablePro
//

import Foundation
import TableProHTTP

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
        return SSEEventStream.make(
            session: session,
            treatForbiddenAsAuthFailure: true,
            wire: ResponsesStreamWire(),
            buildRequest: { [self] in
                try await buildRequest(turns: turns, options: options, stream: true, sessionID: sessionID)
            },
            refreshOnUnauthorized: { [tokenStore] in _ = try await tokenStore.forceRefresh() }
        )
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] {
        guard let version = AIModelReference.shared.provider(ChatGPTCodex.catalogKey)?.clientVersion,
              var components = URLComponents(string: "\(ChatGPTCodex.backendBaseURL)/models")
        else {
            throw AIProviderError.networkError(String(localized: "Failed to fetch models"))
        }
        components.queryItems = [URLQueryItem(name: "client_version", value: version)]
        guard let url = components.url else {
            throw AIProviderError.invalidEndpoint(ChatGPTCodex.backendBaseURL)
        }
        let accessToken = try await tokenStore.validAccessToken()
        let accountID = await tokenStore.accountID() ?? ""
        var request = URLRequest(url: url)
        request.timeoutInterval = AIProvider.modelListTimeout
        for (field, value) in Self.requestHeaders(accessToken: accessToken, accountID: accountID, sessionID: UUID().uuidString) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request, delegate: SameOriginRedirects.shared)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError(String(localized: "Failed to fetch models"))
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw AIProviderError.authenticationFailed("")
        }
        guard httpResponse.statusCode == 200 else {
            throw AIProviderError.mapHTTPError(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let models = Self.decodeModelList(data)
        // The backend answers an older client_version with no models.
        guard !models.isEmpty else {
            throw AIProviderError.networkError(String(localized: "Failed to fetch models"))
        }
        return models
    }

    // Ranked by the backend's priority; hidden entries are internal, and the first one listed is the default.
    static func decodeModelList(_ data: Data) -> [AIModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["models"] as? [[String: Any]]
        else { return [] }
        let listed = entries
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? Int.max) < ($1["priority"] as? Int ?? Int.max) }
            .compactMap(decodeModel(_:))
        return listed.enumerated().map { index, model in
            guard index == 0 else { return model }
            return AIModelInfo(
                id: model.id,
                displayName: model.displayName,
                contextWindow: model.contextWindow,
                modalities: model.modalities,
                reasoning: model.reasoning,
                isProviderDefault: true
            )
        }
    }

    static func decodeModel(_ json: [String: Any]) -> AIModelInfo? {
        guard let slug = json["slug"] as? String, !slug.isEmpty else { return nil }
        let levels = (json["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
        let inputs = json["input_modalities"] as? [String]
        return AIModelInfo(
            id: slug,
            displayName: json["display_name"] as? String,
            contextWindow: json["context_window"] as? Int,
            modalities: inputs.map { $0.contains("image") ? [.text, .image] : [.text] } ?? [],
            reasoning: levels.isEmpty ? nil : AIReasoningSupport(
                mode: .effortOnly,
                effortLevels: ReasoningEffort.levels(fromWire: levels),
                defaultEffort: (json["default_reasoning_level"] as? String).flatMap(ReasoningEffort.init(wireValue:)),
                isMandatory: true,
                canTurnOff: levels.contains { $0.lowercased() == "none" }
            )
        )
    }

    // Listing the models proves the sign-in without spending a turn of the subscription.
    func testConnection() async throws -> Bool {
        _ = try await fetchAvailableModels()
        return true
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

        if let effort = options.reasoningEffort, effort == .off {
            body["reasoning"] = ["effort": effort.wireValue]
        } else if let effort = options.reasoningEffort {
            body["reasoning"] = ["effort": effort.wireValue, "summary": "auto"]
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
