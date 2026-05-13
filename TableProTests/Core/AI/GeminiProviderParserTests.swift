//
//  GeminiProviderParserTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("GeminiProvider stream parser")
struct GeminiProviderParserTests {
    private let stableID = "stable-id"

    private func parse(_ json: [String: Any], state: inout GeminiStreamState) -> [ChatStreamEvent] {
        GeminiProvider.parseChunk(json, state: &state, idGenerator: { self.stableID })
    }

    @Test("Text part yields textDelta")
    func textPart() {
        var state = GeminiStreamState()
        let events = parse([
            "candidates": [[
                "content": [
                    "parts": [["text": "hello"]]
                ]
            ]]
        ], state: &state)
        guard case .textDelta(let text) = events.first else {
            Issue.record("expected textDelta")
            return
        }
        #expect(text == "hello")
    }

    @Test("functionCall part yields the start/delta/end trio in one chunk")
    func functionCallTrio() {
        var state = GeminiStreamState()
        let events = parse([
            "candidates": [[
                "content": [
                    "parts": [[
                        "functionCall": [
                            "name": "list_tables",
                            "args": ["connection_id": "abc"]
                        ]
                    ]]
                ]
            ]]
        ], state: &state)
        #expect(events.count == 3)
        if case .toolUseStart(let id, let name) = events[0] {
            #expect(id == stableID)
            #expect(name == "list_tables")
        } else {
            Issue.record("expected toolUseStart at index 0")
        }
        if case .toolUseDelta(let id, let delta) = events[1] {
            #expect(id == stableID)
            #expect(delta.contains("connection_id"))
            #expect(delta.contains("abc"))
        } else {
            Issue.record("expected toolUseDelta at index 1")
        }
        if case .toolUseEnd(let id) = events[2] {
            #expect(id == stableID)
        } else {
            Issue.record("expected toolUseEnd at index 2")
        }
    }

    @Test("Mixed text + functionCall parts yield events in part order")
    func mixedParts() {
        var state = GeminiStreamState()
        let events = parse([
            "candidates": [[
                "content": [
                    "parts": [
                        ["text": "I'll check"],
                        ["functionCall": ["name": "list_tables", "args": [String: Any]()]]
                    ]
                ]
            ]]
        ], state: &state)
        // Order: textDelta, toolUseStart, toolUseDelta, toolUseEnd
        #expect(events.count == 4)
        guard case .textDelta = events[0] else {
            Issue.record("expected textDelta first")
            return
        }
        guard case .toolUseStart = events[1] else {
            Issue.record("expected toolUseStart second")
            return
        }
    }

    @Test("Empty parts array yields no events")
    func emptyParts() {
        var state = GeminiStreamState()
        let events = parse([
            "candidates": [[
                "content": ["parts": [[String: Any]]()]
            ]]
        ], state: &state)
        #expect(events.isEmpty)
    }

    @Test("usageMetadata populates state token counters")
    func usageTokens() {
        var state = GeminiStreamState()
        _ = parse([
            "usageMetadata": [
                "promptTokenCount": 100,
                "candidatesTokenCount": 50
            ]
        ], state: &state)
        #expect(state.inputTokens == 100)
        #expect(state.outputTokens == 50)
    }

    @Test("encodeArgsToJSONString returns {} on invalid input")
    func argsFallback() {
        let invalid: Any = NSObject()  // not JSON-serializable
        #expect(GeminiProvider.encodeArgsToJSONString(invalid) == "{}")
    }

    @Test("encodeArgsToJSONString round-trips a valid object")
    func argsRoundTrip() {
        let result = GeminiProvider.encodeArgsToJSONString(["a": 1, "b": "x"])
        #expect(result.contains("\"a\""))
        #expect(result.contains("\"b\""))
    }

    @Test("Chunk without candidates yields no events")
    func chunkWithoutCandidates() {
        var state = GeminiStreamState()
        let events = parse(["unrelated": "data"], state: &state)
        #expect(events.isEmpty)
    }

    @Test("Multiple functionCall parts in one chunk get distinct ids")
    func multipleFunctionCallsGetDistinctIds() {
        var state = GeminiStreamState()
        var counter = 0
        let events = GeminiProvider.parseChunk([
            "candidates": [[
                "content": [
                    "parts": [
                        ["functionCall": ["name": "list_tables", "args": [String: Any]()]],
                        ["functionCall": ["name": "describe_table", "args": [String: Any]()]]
                    ]
                ]
            ]]
        ], state: &state, idGenerator: {
            defer { counter += 1 }
            return "id-\(counter)"
        })
        let starts = events.compactMap { event -> String? in
            if case .toolUseStart(let id, _) = event { return id }
            return nil
        }
        #expect(starts == ["id-0", "id-1"])
    }
}
