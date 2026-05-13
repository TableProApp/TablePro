import Foundation

actor BridgeProxy {
    private let host: any MCPMessageTransport
    private let upstream: any MCPMessageTransport
    private let logger: any MCPBridgeLogger

    init(host: any MCPMessageTransport, upstream: any MCPMessageTransport, logger: any MCPBridgeLogger) {
        self.host = host
        self.upstream = upstream
        self.logger = logger
    }

    func run() async {
        await withTaskGroup(of: Void.self) { [host, upstream, logger] group in
            group.addTask { await Self.forward(from: host, to: upstream, direction: "host→upstream", logger: logger) }
            group.addTask { await Self.forward(from: upstream, to: host, direction: "upstream→host", logger: logger) }
            await group.waitForAll()
        }
    }

    private static func forward(
        from source: any MCPMessageTransport,
        to destination: any MCPMessageTransport,
        direction: String,
        logger: any MCPBridgeLogger
    ) async {
        do {
            for try await message in source.inbound {
                do {
                    try await destination.send(message)
                } catch {
                    logger.log(.warning, "[\(direction)] send failed: \(error.localizedDescription)")
                }
            }
            logger.log(.info, "[\(direction)] inbound stream closed")
        } catch {
            logger.log(.error, "[\(direction)] inbound failed: \(error.localizedDescription)")
        }

        await destination.close()
    }
}
