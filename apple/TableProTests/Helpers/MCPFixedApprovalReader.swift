@testable import TablePro

struct MCPFixedApprovalReader: MCPConnectionApprovalReading {
    let approval: MCPConnectionApproval

    init(_ approval: MCPConnectionApproval) {
        self.approval = approval
    }

    func connectionApproval() async -> MCPConnectionApproval {
        approval
    }
}
