//
//  DestructiveToolApprovalTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Destructive tool approval contract")
struct DestructiveToolApprovalTests {
    @Test("ConfirmDestructiveOperationChatTool is agentOnly mode")
    func toolIsAgentOnly() {
        let tool = ConfirmDestructiveOperationChatTool()
        #expect(tool.mode == .agentOnly)
    }

    @Test("agentOnly mode requires approval")
    func agentOnlyRequiresApproval() {
        #expect(ChatToolMode.agentOnly.requiresApproval == true)
    }

    @Test("readOnly mode does not require approval")
    func readOnlyDoesNotRequireApproval() {
        #expect(ChatToolMode.readOnly.requiresApproval == false)
    }

    @Test("write mode requires approval")
    func writeRequiresApproval() {
        #expect(ChatToolMode.write.requiresApproval == true)
    }

    @Test("agentOnly tools are only allowed in agent chat mode")
    func agentOnlyOnlyInAgentMode() {
        #expect(ChatToolMode.agentOnly.isAllowed(in: .agent) == true)
        #expect(ChatToolMode.agentOnly.isAllowed(in: .ask) == false)
        #expect(ChatToolMode.agentOnly.isAllowed(in: .edit) == false)
    }
}
