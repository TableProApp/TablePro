//
//  AppleIntelligenceTransportDiagnosticTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing
#if canImport(FoundationModels)
import FoundationModels

@Suite("AppleIntelligenceTransport diagnostics")
struct AppleIntelligenceTransportDiagnosticTests {
    @available(macOS 26, *)
    private func makeTool(name: String) throws -> AppleIntelligenceTool {
        let spec = ChatToolSpec(
            name: name,
            description: "desc",
            inputSchema: ChatToolSchemaBuilder.object(properties: [:])
        )
        let schema = try AppleIntelligenceSchemaBuilder.buildGenerationSchema(from: spec)
        return AppleIntelligenceTool(spec: spec, schema: schema) { _, _ in "" }
    }

    @available(macOS 26, *)
    @Test("Transcript declares the tools so multi-pass tool calling stays consistent")
    func transcriptDeclaresTools() throws {
        let tools = [try makeTool(name: "list_tables"), try makeTool(name: "run_sql")]
        let transcript = AppleIntelligenceTransport.buildTranscript(
            systemPrompt: "You are helpful.",
            history: [],
            tools: tools
        )
        guard case .instructions(let instructions) = transcript.first else {
            Issue.record("First transcript entry should be instructions")
            return
        }
        #expect(instructions.toolDefinitions.count == 2)
        #expect(instructions.toolDefinitions.map(\.name).sorted() == ["list_tables", "run_sql"])
    }

    @available(macOS 26, *)
    @Test("Tools are declared even when there is no system prompt")
    func transcriptDeclaresToolsWithoutSystemPrompt() throws {
        let transcript = AppleIntelligenceTransport.buildTranscript(
            systemPrompt: nil,
            history: [],
            tools: [try makeTool(name: "list_tables")]
        )
        guard case .instructions(let instructions) = transcript.first else {
            Issue.record("First transcript entry should be instructions carrying the tool definitions")
            return
        }
        #expect(instructions.toolDefinitions.count == 1)
    }

    @available(macOS 26, *)
    @Test("No instructions entry when there is neither a system prompt nor tools")
    func transcriptOmitsInstructionsWhenEmpty() {
        let transcript = AppleIntelligenceTransport.buildTranscript(systemPrompt: nil, history: [], tools: [])
        #expect(transcript.first == nil)
    }
    @available(macOS 26, *)
    @Test("Diagnostic unwraps the underlying error chain")
    func diagnosticUnwrapsUnderlyingChain() {
        let underlying = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1_026)
        let top = NSError(
            domain: "FoundationModels.LanguageModelSession.GenerationError",
            code: -1,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        let diagnostic = AppleIntelligenceTransport.diagnostic(for: top)
        #expect(diagnostic.contains("FoundationModels.LanguageModelSession.GenerationError code=-1"))
        #expect(diagnostic.contains("ModelManagerServices.ModelManagerError code=1026"))
    }

    @available(macOS 26, *)
    @Test("Diagnostic of a plain error has no underlying arrow")
    func diagnosticWithoutUnderlying() {
        let error = NSError(domain: "TestDomain", code: 7)
        let diagnostic = AppleIntelligenceTransport.diagnostic(for: error)
        #expect(diagnostic == "TestDomain code=7")
    }
}
#endif
