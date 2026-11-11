import Foundation

// A seam so the auth policy actor and its tests can state the setting without main-actor settings.
protocol MCPConnectionApprovalReading: Sendable {
    func connectionApproval() async -> MCPConnectionApproval
}

struct MCPSettingsApprovalReader: MCPConnectionApprovalReading {
    func connectionApproval() async -> MCPConnectionApproval {
        await MainActor.run { AppSettingsManager.shared.mcp.connectionApproval }
    }
}
