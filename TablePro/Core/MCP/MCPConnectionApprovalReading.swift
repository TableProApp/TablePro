import Foundation

/// Reads the user's MCP approval setting.
///
/// A seam rather than a direct `AppSettingsManager` read, because the auth policy is an actor and
/// its tests must be able to state the policy without standing up main-actor settings.
protocol MCPConnectionApprovalReading: Sendable {
    func connectionApproval() async -> MCPConnectionApproval
}

struct MCPSettingsApprovalReader: MCPConnectionApprovalReading {
    func connectionApproval() async -> MCPConnectionApproval {
        await MainActor.run { AppSettingsManager.shared.mcp.connectionApproval }
    }
}

struct MCPFixedApprovalReader: MCPConnectionApprovalReading {
    let approval: MCPConnectionApproval

    init(_ approval: MCPConnectionApproval) {
        self.approval = approval
    }

    func connectionApproval() async -> MCPConnectionApproval {
        approval
    }
}
