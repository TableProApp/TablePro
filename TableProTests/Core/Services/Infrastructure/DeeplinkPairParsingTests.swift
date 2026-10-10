//
//  DeeplinkPairParsingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct DeeplinkPairParsingTests {
    private let firstId = UUID()
    private let secondId = UUID()

    private func pairURL(
        connectionIds: String? = nil,
        redirect: String = "http://127.0.0.1:51888/callback",
        extra: [URLQueryItem] = []
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "integrations"
        components.path = "/pair"
        var items = [
            URLQueryItem(name: "client", value: "Raycast"),
            URLQueryItem(name: "challenge", value: "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY"),
            URLQueryItem(name: "redirect", value: redirect),
        ]
        if let connectionIds {
            items.append(URLQueryItem(name: "connection-ids", value: connectionIds))
        }
        components.queryItems = items + extra
        return try #require(components.url)
    }

    private func request(connectionIds: String?) throws -> Result<LaunchIntent, DeeplinkError>? {
        let url = try pairURL(connectionIds: connectionIds)
        return URLClassifier.classify(url)
    }

    private func request(_ extra: [URLQueryItem]) throws -> Result<LaunchIntent, DeeplinkError>? {
        URLClassifier.classify(try pairURL(extra: extra))
    }

    private func refusal(_ outcome: Result<LaunchIntent, DeeplinkError>?) -> DeeplinkError? {
        guard case .some(.failure(let error)) = outcome else { return nil }
        return error
    }

    private func parsed(_ extra: [URLQueryItem]) throws -> PairingRequest {
        let outcome = try request(extra)
        guard case .some(.success(.pairIntegration(let parsed))) = outcome else {
            Issue.record("Expected .pairIntegration, got \(String(describing: outcome))")
            throw CancellationError()
        }
        return parsed
    }

    @Test("An omitted list means every connection")
    func omittedListMeansAll() throws {
        let outcome = try request(connectionIds: nil)
        guard case .some(.success(.pairIntegration(let parsed))) = outcome else {
            Issue.record("Expected .pairIntegration, got \(String(describing: outcome))")
            return
        }
        #expect(parsed.requestedConnectionIds == nil)
    }

    @Test("A well-formed list is honoured as an allowlist")
    func wellFormedListIsHonoured() throws {
        let csv = "\(firstId.uuidString),\(secondId.uuidString)"
        let outcome = try request(connectionIds: csv)
        guard case .some(.success(.pairIntegration(let parsed))) = outcome else {
            Issue.record("Expected .pairIntegration for \(csv)")
            return
        }
        #expect(parsed.requestedConnectionIds == Set([firstId, secondId]))
    }

    @Test("Spaces around an entry do not make it unreadable")
    func spacedListIsHonoured() throws {
        let csv = " \(firstId.uuidString) , \(secondId.uuidString) "
        let outcome = try request(connectionIds: csv)
        guard case .some(.success(.pairIntegration(let parsed))) = outcome else {
            Issue.record("Expected .pairIntegration for a spaced list")
            return
        }
        #expect(parsed.requestedConnectionIds == Set([firstId, secondId]))
    }

    /// The widening this guards against: every entry failing to parse used to collapse the
    /// allowlist to nil, which the approval sheet reads as All Connections. (#2930)
    @Test("A list where nothing parses is refused rather than widened")
    func fullyMalformedListIsRefused() throws {
        let outcome = try request(connectionIds: "not-a-uuid,also-not")
        guard case .some(.failure(.invalidUUID)) = outcome else {
            Issue.record("Expected .invalidUUID, got \(String(describing: outcome))")
            return
        }
    }

    @Test("One unreadable entry refuses the whole list rather than silently narrowing it")
    func partiallyMalformedListIsRefused() throws {
        let outcome = try request(connectionIds: "\(firstId.uuidString),9f1f0c3e-2e3d")
        guard case .some(.failure(.invalidUUID)) = outcome else {
            Issue.record("Expected .invalidUUID, got \(String(describing: outcome))")
            return
        }
    }

    @Test("A list of separators alone is refused")
    func separatorsOnlyListIsRefused() throws {
        let outcome = try request(connectionIds: ",,")
        guard case .some(.failure(.invalidUUID)) = outcome else {
            Issue.record("Expected .invalidUUID, got \(String(describing: outcome))")
            return
        }
    }

    /// Naming the parameter with nothing after it is not the same as leaving it out, and only
    /// leaving it out means every connection.
    @Test("An empty value is refused rather than read as every connection")
    func emptyValueIsRefused() throws {
        let outcome = try request(connectionIds: "")
        guard case .some(.failure(.invalidUUID)) = outcome else {
            Issue.record("Expected .invalidUUID, got \(String(describing: outcome))")
            return
        }
    }

    @Test("A list of only spaces is refused")
    func whitespaceOnlyListIsRefused() throws {
        let outcome = try request(connectionIds: "   ")
        guard case .some(.failure(.invalidUUID)) = outcome else {
            Issue.record("Expected .invalidUUID, got \(String(describing: outcome))")
            return
        }
    }

    @Test("A link without response_mode keeps the legacy delivery and carries no state")
    func absentModeIsLegacy() throws {
        let request = try parsed([])
        #expect(request.responseMode == .legacy)
        #expect(request.state == nil)
    }

    @Test("Both response modes are read, with the state carried as sent")
    func knownModesAreRead() throws {
        let query = try parsed([
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "state", value: "a+b&c=d"),
        ])
        #expect(query.responseMode == .query)
        #expect(query.state == "a+b&c=d")

        let context = try parsed([URLQueryItem(name: "response_mode", value: "context")])
        #expect(context.responseMode == .context)
    }

    @Test("An unknown response_mode is refused before the sheet")
    func unknownModeIsRefused() throws {
        for raw in ["json", "fragment", "form_post", "legacy", "QUERY", ""] {
            let outcome = try request([URLQueryItem(name: "response_mode", value: raw)])
            #expect(refusal(outcome) == .invalidParameter("response_mode"), "response_mode=\(raw)")
        }
        let valueless = try request([URLQueryItem(name: "response_mode", value: nil)])
        #expect(refusal(valueless) == .invalidParameter("response_mode"))
    }

    @Test("A state up to 1,024 UTF-8 bytes is carried, one byte more is refused")
    func stateIsCappedInBytes() throws {
        let longest = String(repeating: "a", count: 1_024)
        #expect(try parsed([URLQueryItem(name: "state", value: longest)]).state == longest)

        let over = try request([URLQueryItem(name: "state", value: longest + "a")])
        #expect(refusal(over) == .invalidParameter("state"))

        let wide = try request([URLQueryItem(name: "state", value: String(repeating: "é", count: 513))])
        #expect(refusal(wide) == .invalidParameter("state"))
    }

    @Test("A redirect back into TablePro is refused before the sheet")
    func selfRedirectIsRefused() throws {
        let loop = "tablepro://integrations/pair?client=x&challenge=y&redirect=z"
        let outcome = URLClassifier.classify(try pairURL(redirect: loop))
        guard case .some(.success(.pairIntegration(let request))) = outcome else {
            Issue.record("Expected .pairIntegration, got \(String(describing: outcome))")
            return
        }
        #expect(request.redirectTarget == nil)
        #expect(throws: PairingValidationError.redirectSchemeNotAllowed("tablepro")) {
            try PairingRedirectValidator.validate(request.redirectURL)
        }
    }
}
