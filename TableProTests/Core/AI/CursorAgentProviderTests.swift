//
//  CursorAgentProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("CursorAgentProvider")
struct CursorAgentProviderTests {
    @Test("Inference arguments stream JSON, pass model and workspace, and end with the prompt")
    func inferenceArgumentsFull() {
        let args = CursorAgentProvider.inferenceArguments(
            prompt: "count the users",
            model: "composer-2",
            workspace: "/tmp/ws"
        )
        #expect(args.contains("-p"))
        #expect(args.contains("stream-json"))
        #expect(args.contains("--stream-partial-output"))
        #expect(args.contains("--trust"))
        #expect(args.contains("--workspace"))
        #expect(args.contains("/tmp/ws"))
        #expect(args.contains("--model"))
        #expect(args.contains("composer-2"))
        #expect(args.last == "count the users")
        #expect(args.dropLast().last == "--", "Prompt must be guarded by -- to prevent argv flag smuggling")
    }

    @Test("A prompt that looks like a flag stays a positional argument")
    func promptThatLooksLikeFlagIsNotParsedAsOption() {
        let args = CursorAgentProvider.inferenceArguments(prompt: "--yolo --workspace /etc", model: "", workspace: nil)
        #expect(args.last == "--yolo --workspace /etc")
        #expect(args.dropLast().last == "--")
    }

    @Test("Inference arguments omit model and workspace when not provided")
    func inferenceArgumentsMinimal() {
        let args = CursorAgentProvider.inferenceArguments(prompt: "hi", model: "", workspace: nil)
        #expect(!args.contains("--model"))
        #expect(!args.contains("--workspace"))
        #expect(args.last == "hi")
    }

    @Test("Assistant text is read from message.content[0].text")
    func assistantTextParsing() {
        let event: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["text": "SELECT count(*) FROM users"]]]
        ]
        #expect(CursorAgentProvider.assistantText(event) == "SELECT count(*) FROM users")
    }

    @Test("Non-assistant events have no assistant text")
    func resultEventHasNoText() {
        let result: [String: Any] = ["type": "result", "duration_ms": 1_234]
        #expect(CursorAgentProvider.assistantText(result) == nil)
    }
}
