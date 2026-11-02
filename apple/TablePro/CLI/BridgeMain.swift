import Foundation
import os
import TableProMCP
import TableProUtilities

@main
struct TableProMcpBridge {
    static func main() async {
        let logger: any MCPBridgeLogger = MCPCompositeBridgeLogger([
            MCPOSBridgeLogger(category: "MCP.Bridge"),
            MCPStderrBridgeLogger()
        ])

        let acquirer = MCPHandshakeAcquirer(logger: logger)
        let opening: MCPVerifiedUpstream
        do {
            opening = try await BridgeUpstreamHandshake.acquireVerified(acquirer: acquirer, logger: logger)
        } catch {
            logger.log(.error, "Bridge startup failed: \(error.localizedDescription)")
            emitFatalJsonRpcError(message: startupMessage(for: error))
            exit(1)
        }

        let upstream = MCPStreamableHttpClientTransport(
            credentialsProvider: BridgeUpstreamHandshake.credentialsProvider(
                opening: opening,
                acquirer: acquirer,
                logger: logger
            ),
            errorLogger: logger
        )

        let proxy = BridgeProxy(upstream: upstream, discovery: opening.discovery, logger: logger)
        await proxy.run()
    }

    private static func startupMessage(for error: Error) -> String {
        switch error {
        case MCPBridgeStartupError.unverifiedInstance:
            return "The local MCP endpoint did not prove it belongs to TablePro. Restart TablePro and try again."
        case MCPBridgeStartupError.unsupportedUpstreamVersion:
            return "This TablePro build does not speak \(MCPProtocolVersion.latest.rawValue). Update TablePro."
        case MCPHandshakeAcquisitionError.serverTurnedOff:
            return error.localizedDescription
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
        try? DescriptorWrite.allBytes(data, to: FileHandle.standardOutput.fileDescriptor)
    }
}
