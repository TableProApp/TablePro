import Foundation
import TableProModels

public protocol SSHProvider: Sendable {
    func createTunnel(
        config: SSHConfiguration,
        connectionId: UUID,
        remoteHost: String,
        remotePort: Int
    ) async throws -> SSHTunnel

    func closeTunnel(for connectionId: UUID) async throws

    func closeTunnel(id: UUID) async throws
}

public struct SSHTunnel: Sendable {
    public let id: UUID
    public let localHost: String
    public let localPort: Int

    public init(id: UUID = UUID(), localHost: String, localPort: Int) {
        self.id = id
        self.localHost = localHost
        self.localPort = localPort
    }
}
