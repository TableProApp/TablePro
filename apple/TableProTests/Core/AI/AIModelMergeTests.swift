//
//  AIModelMergeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// The cases live beside the Rust merge, so both apps are held to the same rules.
struct AIModelMergeTests {
    struct Fixture: Decodable, Sendable {
        struct LiveModel: Decodable, Sendable {
            let id: String
            let name: String?
            let released: String?
            let deprecated: Bool?
            let `default`: Bool?
        }

        struct Expected: Decodable, Sendable, Equatable, CustomStringConvertible {
            let id: String
            let name: String?
            let `default`: Bool
            let deprecated: Bool
            let offline: Bool

            var description: String { "\(id) name=\(name ?? "nil") default=\(`default`) deprecated=\(deprecated) offline=\(offline)" }
        }

        struct Case: Decodable, Sendable, CustomTestStringConvertible {
            let name: String
            let provider: String
            let api: String
            let hidesUnknown: Bool
            let liveOrdered: Bool
            let catalog: AIModelReferenceFile.Provider?
            let live: [LiveModel]?
            let expected: [Expected]

            var testDescription: String { name }

            enum CodingKeys: String, CodingKey {
                case name, provider, api, catalog, live, expected
                case hidesUnknown = "hides_unknown"
                case liveOrdered = "live_ordered"
            }
        }

        let cases: [Case]
    }

    private static let fixtureURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("core/crates/ai/tests/model-merge-cases.json")
    }()

    private static func cases() throws -> [Fixture.Case] {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL)).cases
    }

    @Test(arguments: try cases())
    func mergesLikeTheCore(_ fixture: Fixture.Case) {
        let source = AIModelSource(
            key: fixture.provider,
            api: fixture.api,
            hidesUnknown: fixture.hidesUnknown,
            liveOrdered: fixture.liveOrdered
        )
        let live = fixture.live?.map { model in
            AIModelInfo(
                id: model.id,
                displayName: model.name,
                isDeprecated: model.deprecated ?? false,
                released: AIModelReferenceFile.Model.date(model.released),
                isProviderDefault: model.default ?? false
            )
        }
        let merged = AIModelMerge.merge(live: live, reference: fixture.catalog, source: source).map { model in
            Fixture.Expected(
                id: model.id,
                name: model.displayName,
                default: model.isProviderDefault,
                deprecated: model.isDeprecated,
                offline: model.isOffline
            )
        }
        #expect(merged == fixture.expected, "\(fixture.name)")
    }

    // A fine-tune of a dated snapshot reads that snapshot's entry when the catalog has one.
    @Test
    func lookupTriesTheExactBaseBeforeItsUndatedForm() {
        #expect(AIModelMerge.lookupKeys("ft:gpt-5.5:acme::abc123") == ["ft:gpt-5.5:acme::abc123", "gpt-5.5"])
        #expect(AIModelMerge.lookupKeys("gpt-5.5-2026-04-23") == ["gpt-5.5-2026-04-23", "gpt-5.5"])
        #expect(AIModelMerge.lookupKeys("ft:gpt-4o-2024-08-06:acme::x")
            == ["ft:gpt-4o-2024-08-06:acme::x", "gpt-4o-2024-08-06", "gpt-4o"])
        #expect(AIModelMerge.lookupKeys("claude-opus-5-5") == ["claude-opus-5-5"])
    }
}
