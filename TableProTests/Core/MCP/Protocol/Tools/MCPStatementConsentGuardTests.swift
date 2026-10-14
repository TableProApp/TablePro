//
//  MCPStatementConsentGuardTests.swift
//  TableProTests
//
//  A client that declares elicitation answers its own approval prompt, and TablePro then treats the
//  statement as pre-cleared. Only an admin-scoped token may buy out the Mac dialog that way.
//

import Foundation
@testable import TablePro
import Testing

struct MCPStatementConsentGuardTests {
    private func principal(scopes: Set<MCPScope>, tokenId: UUID) -> MCPPrincipal {
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

    @Test("An admin-scoped token keeps its pre-clearance")
    func adminTokenKeepsPreClearance() {
        let effective = MCPAuthPolicy.effectiveCapabilities(
            [.mayWrite, .confirmationPreCleared],
            for: principal(scopes: [.toolsWrite, .admin], tokenId: UUID())
        )
        #expect(effective.contains(.confirmationPreCleared))
    }
}
