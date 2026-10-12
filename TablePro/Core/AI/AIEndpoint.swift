//
//  AIEndpoint.swift
//  TablePro
//

import Foundation

enum AIEndpointStyle: Sendable, CaseIterable {
    case chatCompletions
    case responses
    case messages
    case gemini
    case ollama

    var apiVersion: String? {
        switch self {
        case .chatCompletions, .responses, .messages: return "v1"
        case .gemini: return "v1beta"
        case .ollama: return nil
        }
    }

    var resourceTerminals: [String] {
        switch self {
        case .chatCompletions: return ["chat/completions", "completions", "models"]
        case .responses: return ["responses", "models"]
        case .messages: return ["messages", "models"]
        case .gemini: return ["models"]
        case .ollama: return ["api/chat", "api/tags"]
        }
    }

    var modelsResource: String {
        switch self {
        case .chatCompletions, .responses, .messages, .gemini: return "models"
        case .ollama: return "api/tags"
        }
    }

    func chatResource(model: String) -> String {
        switch self {
        case .chatCompletions: return "chat/completions"
        case .responses: return "responses"
        case .messages: return "messages"
        case .gemini: return "models/\(model):streamGenerateContent"
        case .ollama: return "api/chat"
        }
    }

    var chatQuery: [URLQueryItem] {
        switch self {
        case .gemini: return [URLQueryItem(name: "alt", value: "sse")]
        case .chatCompletions, .responses, .messages, .ollama: return []
        }
    }
}

struct AIEndpoint: Equatable, Sendable {
    let apiBase: URL

    init?(_ configured: String, style: AIEndpointStyle) {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return nil }

        components.percentEncodedPath = Self.apiBasePath(for: components.percentEncodedPath, style: style)
        guard let url = components.url else { return nil }
        apiBase = url
    }

    func url(appending resource: String, query: [URLQueryItem] = []) -> URL? {
        let target = apiBase.appending(path: resource)
        guard !query.isEmpty else { return target }
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + query
        return components.url
    }

    func chatURL(model: String, style: AIEndpointStyle) -> URL? {
        url(appending: style.chatResource(model: model), query: style.chatQuery)
    }

    /// Works on the percent-encoded path. `URLComponents.path` decodes `%2F`, and writing the
    /// decoded value back turns one segment into two, so a gateway mounted under an escaped
    /// separator would be sent to a different route.
    /// An `Authorization: Bearer` header on a cleartext request to another machine is readable by
    /// anything between here and there. Reaching a server on this machine over http is an ordinary
    /// local setup, so only a remote host is worth saying anything about.
    var isPlaintextToRemoteHost: Bool {
        guard apiBase.scheme?.lowercased() == "http" else { return false }
        guard let host = apiBase.host else { return true }
        return !LoopbackHost.isLoopback(host)
    }

    private static func apiBasePath(for percentEncodedPath: String, style: AIEndpointStyle) -> String {
        let segments = percentEncodedPath.split(separator: "/").map(String.init)

        for terminal in style.resourceTerminals {
            let terminalSegments = terminal.split(separator: "/").map(String.init)
            guard segments.count >= terminalSegments.count,
                  Array(segments.suffix(terminalSegments.count)) == terminalSegments
            else { continue }
            return joined(segments.dropLast(terminalSegments.count))
        }

        guard let apiVersion = style.apiVersion else { return joined(segments) }
        if let last = segments.last, isAPIVersion(last) { return joined(segments) }
        return joined(segments + [apiVersion])
    }

    private static func joined(_ segments: some Collection<String>) -> String {
        segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
    }

    /// `v1`, `v4`, `v1beta`, `v2alpha1`. A leading digit is required, so `vendor` and `v` are not
    /// versions.
    private static func isAPIVersion(_ segment: String) -> Bool {
        guard segment.first == "v" || segment.first == "V" else { return false }
        let rest = segment.dropFirst()
        guard let first = rest.first, first.isNumber else { return false }
        return rest.allSatisfy { $0.isNumber || $0.isLetter || $0 == "." || $0 == "-" || $0 == "_" }
    }
}
