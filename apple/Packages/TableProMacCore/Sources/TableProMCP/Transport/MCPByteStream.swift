import Foundation
import Network

public enum MCPByteStreamState: Sendable, Equatable {
    case ready
    case failed(String)
    case cancelled
}

// One HTTP implementation for TCP and Unix socket clients. `cancel()` must end in `.cancelled`.
public protocol MCPByteStream: AnyObject, Sendable {
    var clientAddress: MCPClientAddress { get }
    func start(stateHandler: @escaping @Sendable (MCPByteStreamState) -> Void)
    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, _ isComplete: Bool, _ failure: String?) -> Void)
    func send(_ data: Data, completion: @escaping @Sendable (_ failure: String?) -> Void)
    func cancel()
}

public final class MCPNetworkByteStream: MCPByteStream, @unchecked Sendable {
    private let connection: NWConnection

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public var clientAddress: MCPClientAddress {
        guard let endpoint = connection.currentPath?.remoteEndpoint else {
            return .remote("unknown")
        }
        guard case .hostPort(let host, _) = endpoint else {
            return .remote(String(describing: endpoint))
        }
        switch host {
        case .ipv4(let address):
            return address.isLoopback ? .loopback : .remote(String(describing: address))
        case .ipv6(let address):
            return address.isLoopback ? .loopback : .remote(String(describing: address))
        case .name(let name, _):
            return name.lowercased() == "localhost" ? .loopback : .remote(name)
        @unknown default:
            return .remote("unknown")
        }
    }

    public func start(stateHandler: @escaping @Sendable (MCPByteStreamState) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                stateHandler(.ready)
            case .failed(let error):
                stateHandler(.failed(error.localizedDescription))
            case .cancelled:
                stateHandler(.cancelled)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    public func receive(
        maximumLength: Int,
        completion: @escaping @Sendable (Data?, _ isComplete: Bool, _ failure: String?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
            completion(content, isComplete, error?.localizedDescription)
        }
    }

    public func send(_ data: Data, completion: @escaping @Sendable (_ failure: String?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error?.localizedDescription)
        })
    }

    public func cancel() {
        connection.cancel()
    }
}
