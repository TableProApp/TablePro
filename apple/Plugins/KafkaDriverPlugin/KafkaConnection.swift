import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import TableProPluginKit

/// Splits the TCP stream into whole Kafka responses. Every response is a 4-byte big-endian
/// length followed by that many bytes, so this is `LengthFieldBasedFrameDecoder`'s shape, but
/// written out because the cap matters: a corrupt or non-Kafka peer can otherwise announce a
/// 2 GB frame and this would sit there allocating for it.
private final class KafkaFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    private static let maximumFrameLength = 256 * 1_024 * 1_024

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= 4 else { return .needMoreData }
        let length = Int(buffer.getInteger(at: buffer.readerIndex, as: Int32.self) ?? 0)
        guard length >= 0, length <= Self.maximumFrameLength else {
            throw KafkaError.malformedResponse(
                "the peer announced a \(length)-byte frame; this is probably not a Kafka broker"
            )
        }
        guard buffer.readableBytes >= 4 + length else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        guard let frame = buffer.readSlice(length: length) else { return .needMoreData }
        context.fireChannelRead(wrapInboundOut(frame))
        return .continue
    }
}

/// Holds the single in-flight request's continuation and resumes it with the next frame.
///
/// The resume-once discipline is the whole job. A channel can deliver a frame, go inactive and
/// report an error in any order, and resuming a continuation twice traps the process, so every
/// path funnels through `finish` and the continuation is cleared before it is resumed.
private final class KafkaResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var pending: CheckedContinuation<ByteBuffer, Error>?
    private var failure: Error?
    private let lock = NIOLock()

    /// Registers the one in-flight request, and says whether the caller may now write.
    ///
    /// A second registration is refused rather than allowed to overwrite the first: dropping a
    /// continuation leaks it and hangs its caller forever, which is far harder to diagnose than
    /// an error naming the overlap. The return value is what stops the refusal being worse than
    /// the overlap: the caller used to be resumed with the error and then write its request
    /// anyway, so the broker answered a request nobody was waiting for and the orphan frame
    /// resumed the NEXT caller, failing it on a correlation id mismatch.
    func expect(_ continuation: CheckedContinuation<ByteBuffer, Error>) -> Bool {
        let resolved: Error? = lock.withLock {
            if let failure { return failure }
            guard pending == nil else {
                return KafkaError.malformedResponse(
                    "two requests overlapped on one Kafka connection; this connection allows one at a time"
                )
            }
            pending = continuation
            return nil
        }
        guard let resolved else { return true }
        continuation.resume(throwing: resolved)
        return false
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        let continuation = lock.withLock { () -> CheckedContinuation<ByteBuffer, Error>? in
            defer { pending = nil }
            return pending
        }
        continuation?.resume(returning: frame)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(with: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(with: KafkaError.connectionFailed(String(localized: "the broker closed the connection")))
    }

    func finish(with error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<ByteBuffer, Error>? in
            if failure == nil { failure = error }
            defer { pending = nil }
            return pending
        }
        continuation?.resume(throwing: error)
    }
}

/// One TCP connection to one broker.
///
/// Requests are strictly one at a time. Kafka allows pipelining, but a browsing client gains
/// nothing from it, and a single in-flight request removes correlation demultiplexing
/// entirely: the correlation id becomes an assertion rather than a routing key.
actor KafkaConnection {
    private let clientId: String
    private var channel: Channel?
    private var handler: KafkaResponseHandler?
    private var correlationId: Int32 = 0
    private var wireSlotIsTaken = false
    private var waitingForWireSlot: [CheckedContinuation<Void, Never>] = []
    private(set) var apiVersions: KafkaApiVersionTable = .preNegotiation

    let endpoint: KafkaEndpoint

    init(endpoint: KafkaEndpoint, clientId: String) {
        self.endpoint = endpoint
        self.clientId = clientId
    }

    var isOpen: Bool { channel?.isActive == true }

    /// Dials the broker, negotiates API versions, and authenticates.
    ///
    /// Cancellation is honoured by closing the channel from the cancellation handler rather
    /// than by hoping the connect returns: `Task.cancel()` cannot interrupt a socket that is
    /// already waiting, and a connect abandoned without closing leaks a live socket.
    func open(
        ssl: SSLConfiguration,
        credentials: KafkaCredentials,
        group: EventLoopGroup,
        timeout: TimeAmount
    ) async throws {
        guard channel == nil else { return }

        let timeoutNanoseconds = UInt64(max(1, timeout.nanoseconds))
        let expiresAt = ProcessInfo.processInfo.systemUptime + TimeInterval(timeoutNanoseconds) / 1_000_000_000
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.close()
        }
        defer { timeoutTask.cancel() }

        let sslContext = try Self.makeSSLContext(ssl)
        let serverHostname = ssl.verifiesHostname ? endpoint.host : nil
        let responseHandler = KafkaResponseHandler()
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    if let sslContext {
                        let tls = try NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)
                        try channel.pipeline.syncOperations.addHandler(tls)
                    }
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(KafkaFrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(responseHandler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let connected: Channel
        do {
            connected = try await PluginNIOChannel.connect(bootstrap, host: endpoint.host, port: endpoint.port)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KafkaError.connectionFailed(PluginNIOChannel.describe(error))
        }

        channel = connected
        handler = responseHandler

        do {
            guard ProcessInfo.processInfo.systemUptime < expiresAt else {
                throw KafkaError.connectionFailed(String(localized: "Timed out while connecting to the Kafka broker"))
            }
            try Task.checkCancellation()
            apiVersions = try await negotiateApiVersions()
            try await authenticate(credentials)
            guard ProcessInfo.processInfo.systemUptime < expiresAt else {
                throw KafkaError.connectionFailed(String(localized: "Timed out while connecting to the Kafka broker"))
            }
        } catch {
            await close()
            throw error
        }
    }

    func close() async {
        let existing = channel
        handler?.finish(with: KafkaError.notConnected)
        channel = nil
        handler = nil
        guard let existing else { return }
        try? await existing.close()
    }

    /// Sends one request and reads its reply.
    ///
    /// Requests queue rather than collide. An actor releases its executor across every `await`,
    /// so two callers that both reach this method interleave, and the wire slot the response
    /// handler guards holds exactly one of them. The queue is what makes a connection shared by
    /// the health monitor's 30-second ping and a running statement work at all; without it
    /// whichever arrived second failed with "two requests overlapped", and a fan-out across
    /// leaders makes a shared connection far more common than it used to be.
    func send(_ request: KafkaRequest) async throws -> KafkaProtocolReader {
        await claimWireSlot()
        defer { releaseWireSlot() }

        guard let channel, let handler, channel.isActive else { throw KafkaError.notConnected }
        try Task.checkCancellation()

        correlationId &+= 1
        let sent = correlationId
        let framed = request.framed(correlationId: sent, clientId: clientId)
        var buffer = channel.allocator.buffer(capacity: framed.count)
        buffer.writeBytes(framed)

        let frame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard handler.expect(continuation) else { return }
                channel.writeAndFlush(buffer).whenFailure { error in
                    handler.finish(with: KafkaError.connectionFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            channel.close(promise: nil)
        }

        let payload = Data(frame.readableBytesView)
        let (received, body) = try KafkaResponseHeader.strip(payload, api: request.api, version: request.version)
        guard received == sent else {
            throw KafkaError.malformedResponse("correlation id \(received) does not match the request's \(sent)")
        }
        return body
    }

    /// Waits for the wire slot.
    ///
    /// Deliberately not cancellable. A waiter that unwound on cancellation would have to resume
    /// itself out of a nonisolated handler and race the holder's release, and the wait it would
    /// be escaping is already bounded: the request ahead ends when the broker answers or when
    /// its own cancellation closes the channel. A cancelled waiter takes the slot and gives it
    /// straight back at the `Task.checkCancellation()` below.
    private func claimWireSlot() async {
        guard wireSlotIsTaken else {
            wireSlotIsTaken = true
            return
        }
        await withCheckedContinuation { waitingForWireSlot.append($0) }
    }

    private func releaseWireSlot() {
        guard !waitingForWireSlot.isEmpty else {
            wireSlotIsTaken = false
            return
        }
        waitingForWireSlot.removeFirst().resume()
    }

    /// Asks the broker what it supports, then never sends a version outside that range.
    ///
    /// A broker that rejects even v3 answers UNSUPPORTED_VERSION with a v0-shaped body, so the
    /// retry at v0 is not defensive padding: it is the documented way to reach an old broker.
    private func negotiateApiVersions() async throws -> KafkaApiVersionTable {
        for version in [KafkaApiKey.apiVersions.highestImplementedVersion, 0] {
            let request = KafkaRequest(api: .apiVersions, version: version) { writer, flexible in
                guard flexible else { return }
                writer.compactString("TablePro")
                writer.compactString(KafkaClientInfo.version)
                writer.emptyTaggedFields()
            }
            var body = try await send(request)
            let errorCode = try body.int16()
            if errorCode == KafkaErrorCode.unsupportedVersion, version != 0 { continue }
            try KafkaErrorCode.check(errorCode, api: "ApiVersions")

            let flexible = KafkaApiKey.apiVersions.isFlexible(version: version)
            let entries = try body.array(compact: flexible) { reader -> (Int16, ClosedRange<Int16>) in
                let key = try reader.int16()
                let minimum = try reader.int16()
                let maximum = try reader.int16()
                if flexible { try reader.taggedFields() }
                return (key, minimum ... Swift.max(minimum, maximum))
            }
            var ranges: [Int16: ClosedRange<Int16>] = [:]
            for entry in entries { ranges[entry.0] = entry.1 }
            return KafkaApiVersionTable(ranges: ranges)
        }
        throw KafkaError.connectionFailed(String(localized: "the broker did not answer an ApiVersions request"))
    }

    private func authenticate(_ credentials: KafkaCredentials) async throws {
        guard let mechanism = credentials.mechanism else { return }
        try await KafkaSASL.authenticate(
            mechanism: mechanism,
            username: credentials.username,
            password: credentials.password,
            connection: self
        )
    }

    func negotiatedVersion(for api: KafkaApiKey) throws -> Int16 {
        try apiVersions.negotiated(api)
    }

    static func tlsConfigurationError(for ssl: SSLConfiguration) -> KafkaError? {
        guard ssl.mode == .verifyCa,
              ssl.caCertificatePath.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return .verifyCaNeedsCertificate
    }

    private static func makeSSLContext(_ ssl: SSLConfiguration) throws -> NIOSSLContext? {
        if let error = tlsConfigurationError(for: ssl) { throw error }
        return try PluginNIOChannel.tlsContext(for: ssl)
    }
}

enum KafkaClientInfo {
    static let version = Bundle(for: KafkaPlugin.self)
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    static let clientId = "tablepro"
}
