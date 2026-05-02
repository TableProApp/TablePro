import Foundation

public struct MCPToolServices: Sendable {
    public let connectionBridge: MCPConnectionBridge
    public let authPolicy: MCPAuthPolicy

    public init(connectionBridge: MCPConnectionBridge, authPolicy: MCPAuthPolicy) {
        self.connectionBridge = connectionBridge
        self.authPolicy = authPolicy
    }
}
