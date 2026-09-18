//
//  MCPStatementConsentGuardTests.swift
//  TableProTests
//
//  A client that declares elicitation answers its own approval prompt, and TablePro then treats the
//  statement as pre-cleared. Only an admin-scoped token may buy out the Mac dialog that way. The
//  enforcement lived in an overload nothing called, so the source scan is half the point: the
//  regression is a missing argument, and the behavioural half cannot see one.
//

import Foundation
@testable import TablePro
import Testing

@Suite("MCP statement consent guard")
struct MCPStatementConsentGuardTests {
    private static let gateSource: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 {
            url.deleteLastPathComponent()
        }
        url.appendPathComponent("TablePro/Core/MCP/Protocol/Tools/MCPStatementGate.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    private func principal(scopes: Set<MCPScope>, tokenId: UUID?) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: "test",
            tokenId: tokenId,
            scopes: scopes,
            metadata: MCPPrincipalMetadata(label: "Test", issuedAt: .distantPast, expiresAt: nil)
        )
    }

    @Test("A write-scoped token cannot pre-clear the confirmation for itself")
    func writeTokenCannotPreClear() {
        let effective = MCPAuthPolicy.effectiveCapabilities(
            [.mayWrite, .confirmationPreCleared],
            for: principal(scopes: [.toolsWrite], tokenId: UUID())
        )
        #expect(!effective.contains(.confirmationPreCleared))
        #expect(!effective.contains(.preCleared))
        #expect(effective.contains(.mayWrite))
    }

    @Test("An anonymous caller cannot pre-clear even holding admin")
    func anonymousAdminCannotPreClear() {
        let effective = MCPAuthPolicy.effectiveCapabilities(
            [.mayWrite, .preCleared, .confirmationPreCleared],
            for: principal(scopes: [.toolsWrite, .admin], tokenId: nil)
        )
        #expect(!effective.contains(.confirmationPreCleared))
        #expect(!effective.contains(.preCleared))
    }

    @Test("An admin-scoped token keeps its pre-clearance")
    func adminTokenKeepsPreClearance() {
        let effective = MCPAuthPolicy.effectiveCapabilities(
            [.mayWrite, .confirmationPreCleared],
            for: principal(scopes: [.toolsWrite, .admin], tokenId: UUID())
        )
        #expect(effective.contains(.confirmationPreCleared))
    }

    /// The stripping only runs on the overload that takes a principal. Calling the other one from
    /// the MCP path is the bypass, and it compiles cleanly.
    @Test("The MCP statement path always names its principal at the Safe Mode gate")
    func statementGatePassesItsPrincipal() throws {
        #expect(!Self.gateSource.isEmpty, "MCPStatementGate.swift was not readable")

        let call = try #require(
            Self.gateSource.range(of: "checkSafeModeDialog("),
            "MCPStatementGate no longer reaches the Safe Mode gate"
        )
        let arguments = Self.gateSource[call.upperBound...].prefix(300)
        #expect(arguments.contains("principal:"), "MCPStatementGate must pass principal: to checkSafeModeDialog")
    }
}
