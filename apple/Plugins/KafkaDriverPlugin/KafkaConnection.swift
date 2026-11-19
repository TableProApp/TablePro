import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import TableProKafkaCore
import TableProPluginKit

private enum KafkaInboundFrame {
    case reply(ByteBuffer)
    case refused(length: Int)
}

// Whole Kafka responses, `LengthFieldBasedFrameDecoder`'s shape written out so a reply past its request's limit is
// refused at its length rather than gathered first.
private final class KafkaFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = KafkaInboundFrame

    private var splitter = KafkaFrameSplitter()
    private let limits: KafkaResponseHandler

    init(limits: KafkaResponseHandler) {
        self.limits = limits
    }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let announced = buffer.readableBytes >= 4 ? buffer.getInteger(at: buffer.readerIndex, as: Int32.self) : nil
        switch try splitter.next(readable: buffer.readableBytes, announcedLength: announced, limit: limits.replyLimit) {
        case .needMoreData:
            return .needMoreData
        case .skip(let count):
            buffer.moveReaderIndex(forwardBy: count)
            return .continue
        case .refuse(let length):
            buffer.moveReaderIndex(forwardBy: 4)
            context.fireChannelRead(wrapInboundOut(.refused(length: length)))
            return .continue
        case .reply(let length):
            buffer.moveReaderIndex(forwardBy: 4)
            guard let frame = buffer.readSlice(length: length) else { return .needMoreData }
            context.fireChannelRead(wrapInboundOut(.reply(frame)))
            return .continue
        }
    }
}

/// Holds the single in-flight request's continuation and resumes it with the next frame.
///
/// The resume-once discipline is the whole job. A channel can deliver a frame, go inactive and
/// report an error in any order, and resuming a continuation twice traps the process, so every
/// path funnels through `finish` and the continuation is cleared before it is resumed.
private final class KafkaResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = KafkaInboundFrame

    private var pending: CheckedContinuation<ByteBuffer, Error>?
    private var pendingLimit: Int?
    private var failure: Error?
    private let lock = NIOLock()

    // The longest reply the request in flight takes; the next reply on the wire is always its own.
    var replyLimit: Int {
        lock.withLock { pendingLimit ?? KafkaFrameSplitter.maximumFrameLength }
    }

    /// Registers the one in-flight request, and says whether the caller may now write.
    ///
    /// A second registration is refused rather than allowed to overwrite the first: dropping a
    /// continuation leaks it and hangs its caller forever, which is far harder to diagnose than
    /// an error naming the overlap. The return value is what stops the refusal being worse than
    /// the overlap: the caller used to be resumed with the error and then write its request
    /// anyway, so the broker answered a request nobody was waiting for and the orphan frame
    /// resumed the NEXT caller, failing it on a correlation id mismatch.
    func expect(_ continuation: CheckedContinuation<ByteBuffer, Error>, replyLimit: Int?) -> Bool {
        let resolved: Error? = lock.withLock {
            if let failure { return failure }
            guard pending == nil else {
                return KafkaError.malformedResponse(
                    "two requests overlapped on one Kafka connection; this connection allows one at a time"
                )
            }
            pending = continuation
            pendingLimit = replyLimit
            return nil
        }
        guard let resolved else { return true }
        continuation.resume(throwing: resolved)
        return false
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let continuation = lock.withLock { () -> CheckedContinuation<ByteBuffer, Error>? in
            defer {
                pending = nil
                pendingLimit = nil
            }
            return pending
        }
        switch unwrapInboundIn(data) {
        case .reply(let frame):
            continuation?.resume(returning: frame)
        case .refused(let length):
            continuation?.resume(throwing: KafkaError.malformedResponse(
                "the broker answered with \(length) bytes, more than the request allows"
            ))
        }
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
            defer {
                pending = nil
                pendingLimit = nil
            }
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
        tlsServerName: String,
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
        let serverHostname = ssl.verifiesHostname ? tlsServerName : nil
        let responseHandler = KafkaResponseHandler()
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    if let sslContext {
                        let tls = try NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)
                        try channel.pipeline.syncOperations.addHandler(tls)
                    }
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(KafkaFrameDecoder(limits: responseHandler))
                    )
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
    // A reply longer than `replyLimit` is refused before any of it is kept, and the connection stays usable.
    func send(_ request: KafkaRequest, replyLimit: Int? = nil) async throws -> KafkaProtocolReader {
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
                guard handler.expect(continuation, replyLimit: replyLimit) else { return }
                channel.writeAndFlush(buffer).whenFailure { error in
                    handler.finish(with: KafkaError.connectionFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            channel.close(promise: nil)
        }

        // Copied once, into the reader's own bytes: a fetch budget counts a reply and one copy of it.
        let payload = [UInt8](frame.readableBytesView)
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
