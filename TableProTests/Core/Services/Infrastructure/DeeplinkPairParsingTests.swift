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

    private func pairURL(connectionIds: String?) throws -> URL {
        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "integrations"
        components.path = "/pair"
        var items = [
            URLQueryItem(name: "client", value: "Raycast"),
            URLQueryItem(name: "challenge", value: "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY"),
            URLQueryItem(name: "redirect", value: "http://127.0.0.1:51888/callback"),
        ]
        if let connectionIds {
            items.append(URLQueryItem(name: "connection-ids", value: connectionIds))
        }
        components.queryItems = items
        return try #require(components.url)
    }

    private func request(connectionIds: String?) throws -> Result<LaunchIntent, DeeplinkError>? {
        let url = try pairURL(connectionIds: connectionIds)
        return URLClassifier.classify(url)
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
}
