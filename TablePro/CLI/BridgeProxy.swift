import Foundation
import os

struct BridgeDiscovery: Sendable {
    let supportedVersions: [String]
    let capabilities: JsonValue
    let serverInfo: JsonValue?
    let instructions: String?
    let instanceId: String?
}

enum MCPBridgeStartupError: Error, LocalizedError {
    case invalidEndpoint
    case discoveryFailed(String)
    case unverifiedInstance
    case unsupportedUpstreamVersion([String])

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The MCP handshake does not describe a usable endpoint"
        case .discoveryFailed(let detail):
            return "server/discover failed: \(detail)"
        case .unverifiedInstance:
            return "The MCP server did not prove it is the TablePro instance that wrote the handshake"
        case .unsupportedUpstreamVersion(let advertised):
            let versions = advertised.joined(separator: ", ")
            return "The MCP server does not speak \(MCPProtocolVersion.latest.rawValue), only \(versions)"
        }
    }
}

enum BridgeUpstreamHandshake {
    private static let probeTimeout: Duration = .seconds(10)
    private static let probeRequestId = JsonRpcId.string("tablepro-bridge-discover")

    static func verifiedDiscovery(
        handshake: MCPHandshakePayload,
        credentials: MCPUpstreamCredentials,
        logger: any MCPBridgeLogger
    ) async throws -> BridgeDiscovery {
        let transport = MCPStreamableHttpClientTransport(
            credentialsProvider: MCPCachedUpstreamCredentialsProvider(initial: credentials) { credentials },
            errorLogger: logger
        )
        defer { Task { await transport.close() } }

        let discovery = try await probe(transport: transport)

        guard discovery.supportedVersions.contains(MCPProtocolVersion.latest.rawValue) else {
            throw MCPBridgeStartupError.unsupportedUpstreamVersion(discovery.supportedVersions)
        }
        guard let advertised = discovery.instanceId, advertised == handshake.instanceId else {
            throw MCPBridgeStartupError.unverifiedInstance
        }
        return discovery
    }

    private static func probe(transport: MCPStreamableHttpClientTransport) async throws -> BridgeDiscovery {
        let params = JsonValue.object([
            "_meta": .object([
                MCPMetaKeys.protocolVersion: .string(MCPProtocolVersion.latest.rawValue),
                MCPMetaKeys.clientCapabilities: .object([:]),
                MCPMetaKeys.clientInfo: .object([
                    "name": .string(BridgeIdentity.name),
                    "version": .string(BridgeIdentity.version)
                ])
            ])
        ])
        let request = JsonRpcRequest(id: probeRequestId, method: "server/discover", params: params)
        let body = try JsonRpcCodec.encode(.request(request))
        try await transport.send(
            MCPUpstreamFrame(body: body, method: "server/discover", requestId: probeRequestId)
        )

        return try await withThrowingTaskGroup(of: BridgeDiscovery.self) { group in
            group.addTask {
                for try await payload in transport.inbound {
                    guard let message = try? JsonRpcCodec.decode(payload) else { continue }
                    switch message {
                    case .successResponse(let success) where success.id == probeRequestId:
                        return parse(success.result)
                    case .errorResponse(let failure) where failure.id == probeRequestId:
                        throw MCPBridgeStartupError.discoveryFailed(failure.error.message)
                    default:
                        continue
                    }
                }
                throw MCPBridgeStartupError.discoveryFailed("upstream closed before answering")
            }
            group.addTask {
                try await Task.sleep(for: probeTimeout)
                throw MCPBridgeStartupError.discoveryFailed("timed out")
            }
            guard let first = try await group.next() else {
                throw MCPBridgeStartupError.discoveryFailed("no answer")
            }
            group.cancelAll()
            return first
        }
    }

    private static func parse(_ result: JsonValue) -> BridgeDiscovery {
        BridgeDiscovery(
            supportedVersions: result["supportedVersions"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            capabilities: result["capabilities"] ?? .object([:]),
            serverInfo: result["_meta"]?[MCPMetaKeys.serverInfo],
            instructions: result["instructions"]?.stringValue,
            instanceId: result["_meta"]?[MCPServerInstanceIdentity.metaKey]?.stringValue
        )
    }
}

enum BridgeIdentity {
    static let name = "tablepro-mcp"
    static let version: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }()
}

actor BridgeProxy {
    private static let initializeMethod = "initialize"
    private static let initializedNotification = "notifications/initialized"
    private static let pingMethod = "ping"
    private static let defaultLegacyVersion = MCPProtocolVersion.v20251125

    private let upstream: MCPStreamableHttpClientTransport
    private let stdout: BridgeStdout
    private let hostLines: AsyncStream<Data>
    private let logger: any MCPBridgeLogger
    private let discovery: BridgeDiscovery

    private var clientInfo: JsonValue?

    init(
        upstream: MCPStreamableHttpClientTransport,
        discovery: BridgeDiscovery,
        logger: any MCPBridgeLogger,
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput
    ) {
        self.upstream = upstream
        self.discovery = discovery
        self.logger = logger
        self.stdout = BridgeStdout(handle: stdout)
        self.hostLines = BridgeStdin.lines(from: stdin)
    }

    func run() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pumpHost() }
            group.addTask { await self.pumpUpstream() }
            _ = await group.next()
            group.cancelAll()
        }
        await upstream.close()
    }

    private func pumpHost() async {
        for await line in hostLines {
            await handle(line)
        }
        logger.log(.info, "Host closed stdin")
    }

    private func pumpUpstream() async {
        do {
            for try await payload in upstream.inbound {
                await stdout.write(payload)
            }
        } catch {
            logger.log(.error, "Upstream stream ended: \(error)")
        }
    }

    private func handle(_ line: Data) async {
        guard let peek = BridgeMessagePeek(line) else {
            logger.log(.warning, "Skipping a malformed line from the host")
            return
        }
        if peek.isResponse {
            logger.log(.warning, "Dropping a JSON-RPC response written to stdin")
            return
        }
        guard let method = peek.method else {
            logger.log(.warning, "Dropping a message with no method")
            return
        }

        switch method {
        case Self.initializeMethod:
            await answerInitialize(line: line, peek: peek)
        case Self.initializedNotification:
            return
        case Self.pingMethod:
            await answerPing(peek: peek)
        default:
            await forward(line: line, peek: peek, method: method)
        }
    }

    private func forward(line: Data, peek: BridgeMessagePeek, method: String) async {
        var body = line
        if !peek.declaresProtocolVersion {
            if let stamped = BridgeJson.stampMeta(line, fields: metaFields()) {
                body = stamped
            } else {
                logger.log(.warning, "Could not stamp request metadata onto \(method)")
            }
        }

        do {
            try await upstream.send(
                MCPUpstreamFrame(body: body, method: method, name: peek.name, requestId: peek.id)
            )
        } catch {
            logger.log(.error, "Forwarding \(method) failed: \(error)")
            await fail(peek.id, message: "The TablePro bridge could not forward this request: \(error)")
        }
    }

    private func answerInitialize(line: Data, peek: BridgeMessagePeek) async {
        guard let id = peek.id else {
            logger.log(.warning, "Ignoring an initialize with no id")
            return
        }

        let params = Self.requestParams(line)
        clientInfo = params?["clientInfo"]
        let negotiated = Self.negotiate(requested: params?["protocolVersion"]?.stringValue)

        var result: [String: JsonValue] = [
            "protocolVersion": .string(negotiated.rawValue),
            "capabilities": Self.legacyCapabilities(from: discovery.capabilities)
        ]
        if let serverInfo = discovery.serverInfo {
            result["serverInfo"] = serverInfo
        }
        if let instructions = discovery.instructions {
            result["instructions"] = .string(instructions)
        }

        await respond(id: id, result: .object(result))
        logger.log(.info, "Terminated a legacy initialize at \(negotiated.rawValue)")
    }

    private func answerPing(peek: BridgeMessagePeek) async {
        guard let id = peek.id else { return }
        await respond(id: id, result: .object([:]))
    }

    private func respond(id: JsonRpcId, result: JsonValue) async {
        let response = JsonRpcSuccessResponse(id: id, result: result)
        guard let data = try? JsonRpcCodec.encode(.successResponse(response)) else { return }
        await stdout.write(data)
    }

    private func fail(_ id: JsonRpcId?, message: String) async {
        guard let id else { return }
        let response = JsonRpcErrorResponse(
            id: id,
            error: JsonRpcError(code: JsonRpcErrorCode.internalError, message: message)
        )
        guard let data = try? JsonRpcCodec.encode(.errorResponse(response)) else { return }
        await stdout.write(data)
    }

    private func metaFields() -> Data {
        var fields = Data("\"\(MCPMetaKeys.protocolVersion)\":\"\(MCPProtocolVersion.latest.rawValue)\"".utf8)
        fields.append(Data(",\"\(MCPMetaKeys.clientCapabilities)\":{}".utf8))
        guard let clientInfo, let encoded = try? JSONEncoder().encode(clientInfo) else { return fields }
        fields.append(Data(",\"\(MCPMetaKeys.clientInfo)\":".utf8))
        fields.append(encoded)
        return fields
    }

    private static func requestParams(_ line: Data) -> JsonValue? {
        guard let message = try? JsonRpcCodec.decode(line), case .request(let request) = message else {
            return nil
        }
        return request.params
    }

    private static func negotiate(requested: String?) -> MCPProtocolVersion {
        guard let requested else { return defaultLegacyVersion }
        let version = MCPProtocolVersion(requested)
        return MCPProtocolVersion.legacy.contains(version) ? version : defaultLegacyVersion
    }

    private static func legacyCapabilities(from advertised: JsonValue) -> JsonValue {
        guard var fields = advertised.objectValue else { return .object([:]) }
        fields.removeValue(forKey: "extensions")
        if let resources = fields["resources"]?.objectValue {
            var lowered = resources
            lowered["subscribe"] = .bool(false)
            fields["resources"] = .object(lowered)
        }
        return .object(fields)
    }
}

struct BridgeMessagePeek {
    let id: JsonRpcId?
    let method: String?
    let name: String?
    let isResponse: Bool
    let declaresProtocolVersion: Bool

    init?(_ line: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else { return nil }
        id = envelope.id
        method = envelope.method
        name = envelope.params?.name ?? envelope.params?.uri
        isResponse = envelope.isResponse
        declaresProtocolVersion = envelope.params?.meta?.protocolVersion?.isEmpty == false
    }

    private struct Envelope: Decodable {
        let id: JsonRpcId?
        let method: String?
        let params: Params?
        let isResponse: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case method
            case params
            case result
            case error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decodeIfPresent(JsonRpcId.self, forKey: .id)) ?? nil
            method = (try? container.decodeIfPresent(String.self, forKey: .method)) ?? nil
            params = (try? container.decodeIfPresent(Params.self, forKey: .params)) ?? nil
            isResponse = container.contains(.result) || container.contains(.error)
        }
    }

    private struct Params: Decodable {
        let name: String?
        let uri: String?
        let meta: Meta?

        enum CodingKeys: String, CodingKey {
            case name
            case uri
            case meta = "_meta"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
            uri = (try? container.decodeIfPresent(String.self, forKey: .uri)) ?? nil
            meta = (try? container.decodeIfPresent(Meta.self, forKey: .meta)) ?? nil
        }
    }

    private struct Meta: Decodable {
        let protocolVersion: String?

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "io.modelcontextprotocol/protocolVersion"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = (try? container.decodeIfPresent(String.self, forKey: .protocolVersion)) ?? nil
        }
    }
}

enum BridgeJson {
    private static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D
    private static let openBracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D
    private static let quote: UInt8 = 0x22
    private static let backslash: UInt8 = 0x5C
    private static let colon: UInt8 = 0x3A
    private static let comma: UInt8 = 0x2C

    static func stampMeta(_ body: Data, fields: Data) -> Data? {
        let bytes = [UInt8](body)
        guard let objectOpen = topLevelObjectStart(bytes) else { return nil }

        guard let paramsStart = memberValueStart(bytes, objectOpen: objectOpen, key: "params") else {
            var wrapped = Data("\"params\":{\"_meta\":{".utf8)
            wrapped.append(fields)
            wrapped.append(Data("}}".utf8))
            return insert(wrapped, into: bytes, afterOpen: objectOpen)
        }
        guard bytes[paramsStart] == openBrace else { return nil }

        if let metaStart = memberValueStart(bytes, objectOpen: paramsStart, key: "_meta") {
            guard bytes[metaStart] == openBrace else { return nil }
            return insert(fields, into: bytes, afterOpen: metaStart)
        }

        var member = Data("\"_meta\":{".utf8)
        member.append(fields)
        member.append(closeBrace)
        return insert(member, into: bytes, afterOpen: paramsStart)
    }

    private static func insert(_ payload: Data, into bytes: [UInt8], afterOpen open: Int) -> Data {
        var index = open + 1
        skipWhitespace(bytes, &index)
        let isEmptyObject = index < bytes.count && bytes[index] == closeBrace

        var output = Data(bytes[0...open])
        output.append(payload)
        if !isEmptyObject {
            output.append(comma)
        }
        output.append(contentsOf: bytes[(open + 1)...])
        return output
    }

    private static func topLevelObjectStart(_ bytes: [UInt8]) -> Int? {
        var index = 0
        skipWhitespace(bytes, &index)
        guard index < bytes.count, bytes[index] == openBrace else { return nil }
        return index
    }

    private static func memberValueStart(_ bytes: [UInt8], objectOpen: Int, key: String) -> Int? {
        var index = objectOpen + 1
        let target = Array(key.utf8)

        while index < bytes.count {
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] != closeBrace else { return nil }
            guard let keyRange = scanString(bytes, &index) else { return nil }
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == colon else { return nil }
            index += 1
            skipWhitespace(bytes, &index)
            guard index < bytes.count else { return nil }
            if Array(bytes[keyRange]) == target {
                return index
            }
            guard skipValue(bytes, &index) else { return nil }
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == comma else { return nil }
            index += 1
        }
        return nil
    }

    private static func skipValue(_ bytes: [UInt8], _ index: inout Int) -> Bool {
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case quote:
            return scanString(bytes, &index) != nil
        case openBrace, openBracket:
            return skipContainer(bytes, &index)
        default:
            while index < bytes.count, !isStructural(bytes[index]), !isWhitespace(bytes[index]) {
                index += 1
            }
            return true
        }
    }

    private static func skipContainer(_ bytes: [UInt8], _ index: inout Int) -> Bool {
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote {
                guard scanString(bytes, &index) != nil else { return false }
                continue
            }
            if byte == openBrace || byte == openBracket {
                depth += 1
                index += 1
                continue
            }
            if byte == closeBrace || byte == closeBracket {
                depth -= 1
                index += 1
                if depth == 0 { return true }
                continue
            }
            index += 1
        }
        return false
    }

    private static func scanString(_ bytes: [UInt8], _ index: inout Int) -> Range<Int>? {
        guard index < bytes.count, bytes[index] == quote else { return nil }
        index += 1
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == backslash {
                index += 2
                continue
            }
            if byte == quote {
                let range = start..<index
                index += 1
                return range
            }
            index += 1
        }
        return nil
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, isWhitespace(bytes[index]) {
            index += 1
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isStructural(_ byte: UInt8) -> Bool {
        byte == comma || byte == colon || byte == closeBrace || byte == closeBracket
    }
}

enum BridgeStdin {
    static func lines(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let reader = Task.detached(priority: .userInitiated) {
                var buffer = Data()
                while !Task.isCancelled {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[buffer.startIndex..<newline])
                        buffer.removeSubrange(buffer.startIndex...newline)
                        yieldLine(line, to: continuation)
                    }
                }
                yieldLine(buffer, to: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    private static func yieldLine(_ line: Data, to continuation: AsyncStream<Data>.Continuation) {
        var trimmed = line
        if trimmed.last == 0x0D {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return }
        continuation.yield(trimmed)
    }
}

actor BridgeStdout {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ payload: Data) {
        var line = payload
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
        } catch {
            FileHandle.standardError.write(Data("[error] stdout write failed: \(error)\n".utf8))
        }
    }
}
