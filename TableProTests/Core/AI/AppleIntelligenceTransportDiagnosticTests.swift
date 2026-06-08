//
//  AppleIntelligenceTransportDiagnosticTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing
#if canImport(FoundationModels)

@Suite("AppleIntelligenceTransport diagnostics")
struct AppleIntelligenceTransportDiagnosticTests {
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
