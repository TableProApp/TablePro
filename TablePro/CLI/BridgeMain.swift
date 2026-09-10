import Foundation
import os

@main
struct TableProMcpBridge {
    static func main() async {
        let logger: any MCPBridgeLogger = MCPCompositeBridgeLogger([
            MCPOSBridgeLogger(category: "MCP.Bridge"),
            MCPStderrBridgeLogger()
        ])

        let acquirer = MCPHandshakeAcquirer(logger: logger)
        guard let opening = await openUpstream(acquirer: acquirer, logger: logger) else {
            exit(1)
        }

        let credentialsProvider = MCPCachedUpstreamCredentialsProvider(initial: opening.credentials) {
            let refreshed = try await acquirer.acquire()
            guard let credentials = refreshed.credentials() else {
                throw MCPBridgeStartupError.invalidEndpoint
            }
            _ = try await BridgeUpstreamHandshake.verifiedDiscovery(
                handshake: refreshed,
                credentials: credentials,
                logger: logger
            )
            logger.log(.info, "Re-acquired and verified the MCP handshake")
            return credentials
        }

        let upstream = MCPStreamableHttpClientTransport(
            credentialsProvider: credentialsProvider,
            errorLogger: logger
        )

        let proxy = BridgeProxy(upstream: upstream, discovery: opening.discovery, logger: logger)
        await proxy.run()
    }

    private static func openUpstream(
        acquirer: MCPHandshakeAcquirer,
        logger: any MCPBridgeLogger
    ) async -> (credentials: MCPUpstreamCredentials, discovery: BridgeDiscovery)? {
        do {
            let handshake = try await acquirer.acquire()
            guard let credentials = handshake.credentials() else {
                throw MCPBridgeStartupError.invalidEndpoint
            }
            let discovery = try await BridgeUpstreamHandshake.verifiedDiscovery(
                handshake: handshake,
                credentials: credentials,
                logger: logger
            )
            return (credentials, discovery)
        } catch {
            logger.log(.error, "Bridge startup failed: \(error.localizedDescription)")
            emitFatalJsonRpcError(message: startupMessage(for: error))
            return nil
        }
    }

    private static func startupMessage(for error: Error) -> String {
        switch error {
        case MCPBridgeStartupError.unverifiedInstance:
            return "The local MCP endpoint did not prove it belongs to TablePro. Restart TablePro and try again."
        case MCPBridgeStartupError.unsupportedUpstreamVersion:
            return "This TablePro build does not speak \(MCPProtocolVersion.latest.rawValue). Update TablePro."
        default:
            return "TablePro is not running. Launch the app and enable the MCP server."
        }
    }

    private static func emitFatalJsonRpcError(message: String) {
        let envelope = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(
                id: nil,
                error: JsonRpcError(
                    code: JsonRpcErrorCode.serverError,
                    message: message,
                    data: nil
                )
            )
        )
        guard let data = try? JsonRpcCodec.encodeLine(envelope) else { return }
        FileHandle.standardOutput.write(data)
    }
}
