import Foundation

@main
struct TableProMcpBridge {
    static func main() async {
        let logger: any MCPBridgeLogger = MCPCompositeBridgeLogger([
            MCPOSBridgeLogger(category: "MCP.Bridge"),
            MCPStderrBridgeLogger()
        ])

        let acquirer = MCPHandshakeAcquirer(logger: logger)
        let handshake: MCPBridgeHandshake
        do {
            handshake = try await acquirer.acquire()
        } catch {
            logger.log(.error, "Handshake failed: \(error.localizedDescription)")
            emitFatalJsonRpcError(message: "TablePro is not running. Launch the app and enable the MCP server.")
            exit(1)
        }

        guard let endpoint = handshake.endpoint() else {
            logger.log(.error, "Handshake produced invalid endpoint")
            emitFatalJsonRpcError(message: "Invalid MCP server endpoint")
            exit(1)
        }

        let upstream = MCPStreamableHttpClientTransport(
            configuration: MCPStreamableHttpClientConfiguration(
                endpoint: endpoint,
                bearerToken: handshake.token,
                tlsCertFingerprint: handshake.tlsCertFingerprint,
                requestTimeout: .seconds(60),
                serverInitiatedStream: false
            ),
            errorLogger: logger
        )

        let host = MCPStdioMessageTransport(errorLogger: logger)

        let proxy = BridgeProxy(host: host, upstream: upstream, logger: logger)
        await proxy.run()
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
