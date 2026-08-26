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

    private static let maximumFrameLength = 256 * 1024 * 1024

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

    /// Registers the one in-flight request. A second registration is refused rather than
    /// allowed to overwrite the first: dropping a continuation leaks it and hangs its caller
    /// forever, which is far harder to diagnose than an error naming the overlap.
    func expect(_ continuation: CheckedContinuation<ByteBuffer, Error>) {
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
        if let resolved { continuation.resume(throwing: resolved) }
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

/// Resumes a connect's caller exactly once, whichever of the connect and the cancellation
/// gets there first.
private final class ConnectGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Channel, Error>?
    private var settled = false
    private let lock = NIOLock()

    func arm(_ continuation: CheckedContinuation<Channel, Error>) {
        let alreadySettled: Bool = lock.withLock {
            if settled { return true }
            self.continuation = continuation
            return false
        }
        // Cancellation can land before the continuation is armed, so the check is not
        // redundant: without it the caller would wait forever for a gate already closed.
        if alreadySettled { continuation.resume(throwing: CancellationError()) }
    }

    /// Returns false when the caller has already been resumed, meaning the channel is unowned.
    func deliver(_ channel: Channel) -> Bool {
        let waiting = take()
        guard let waiting else { return false }
        waiting.resume(returning: channel)
        return true
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    func cancel() {
        take()?.resume(throwing: CancellationError())
    }

    private func take() -> CheckedContinuation<Channel, Error>? {
        lock.withLock {
            guard !settled else { return nil }
            settled = true
            defer { continuation = nil }
            return continuation
        }
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
            connected = try await Self.connect(bootstrap, host: endpoint.host, port: endpoint.port)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NIOSSLError {
            throw KafkaError.connectionFailed(Self.describeTLS(error))
        } catch let error as NIOSSLExtraError {
            throw KafkaError.connectionFailed(Self.describeTLSExtra(error))
        } catch {
            throw KafkaError.connectionFailed(Self.describeConnect(error))
        }

        channel = connected
        handler = responseHandler

        do {
            try Task.checkCancellation()
            apiVersions = try await negotiateApiVersions()
            try await authenticate(credentials)
        } catch {
            await close()
            throw error
        }
    }

    /// Dials, and returns as soon as the caller is cancelled rather than waiting out the
    /// connect timeout.
    ///
    /// Cancelling a `Task` cannot interrupt a connect already in flight, so the two have to be
    /// raced: whichever arrives first resumes the caller, and the loser cleans up after
    /// itself. Without this a cancelled connect sat for the full timeout, which is the shape
    /// CLAUDE.md's cancellation invariant exists to prevent, and it was measured at 60s.
    private static func connect(_ bootstrap: ClientBootstrap, host: String, port: Int) async throws -> Channel {
        let gate = ConnectGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.arm(continuation)
                bootstrap.connect(host: host, port: port).whenComplete { result in
                    switch result {
                    case .success(let channel):
                        // A channel that arrives after the caller gave up belongs to nobody,
                        // so it is closed here rather than leaked.
                        if !gate.deliver(channel) { channel.close(promise: nil) }
                    case .failure(let error):
                        gate.fail(error)
                    }
                }
            }
        } onCancel: {
            gate.cancel()
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
    func send(_ request: KafkaRequest) async throws -> KafkaProtocolReader {
        guard let channel, let handler, channel.isActive else { throw KafkaError.notConnected }
        try Task.checkCancellation()

        correlationId &+= 1
        let sent = correlationId
        let framed = request.framed(correlationId: sent, clientId: clientId)
        var buffer = channel.allocator.buffer(capacity: framed.count)
        buffer.writeBytes(framed)

        let frame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handler.expect(continuation)
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

    private static func makeSSLContext(_ ssl: SSLConfiguration) throws -> NIOSSLContext? {
        guard ssl.isEnabled else { return nil }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = verification(for: ssl.mode)

        if ssl.verifiesCertificate, !ssl.caCertificatePath.isEmpty {
            configuration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(ssl.caCertificatePath))
        }
        if !ssl.clientCertificatePath.isEmpty {
            let chain = try NIOSSLCertificate.fromPEMFile(ssl.clientCertificatePath)
            configuration.certificateChain = chain.map { .certificate($0) }
        }
        if !ssl.clientKeyPath.isEmpty {
            configuration.privateKey = .privateKey(try NIOSSLPrivateKey(file: ssl.clientKeyPath, format: .pem))
        }
        return try NIOSSLContext(configuration: configuration)
    }

    private static func verification(for mode: SSLMode) -> CertificateVerification {
        switch mode {
        case .verifyIdentity: return .fullVerification
        case .verifyCa: return .noHostnameVerification
        default: return .none
        }
    }

    private static func describeTLS(_ error: NIOSSLError) -> String {
        switch error {
        case .handshakeFailed:
            return String(localized: "the TLS handshake failed")
        case .failedToLoadCertificate:
            return String(localized: "the certificate file could not be read")
        case .failedToLoadPrivateKey:
            return String(localized: "the private key file could not be read")
        default:
            return String(describing: error)
        }
    }

    private static func describeTLSExtra(_ error: NIOSSLExtraError) -> String {
        switch error {
        case .failedToValidateHostname:
            return String(localized: "the broker's certificate does not cover the hostname you connected to")
        default:
            return String(describing: error)
        }
    }

    /// A Kafka listener that is not actually a Kafka listener is a common misconfiguration, so
    /// the two failures worth naming are the ones a user can act on. Each names only what went
    /// wrong: what to do about it belongs in the docs, and a second sentence here would make
    /// the error unusable as a heading anyone could search for.
    private static func describeConnect(_ error: Error) -> String {
        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            return String(localized: "the connection timed out")
        }
        if let ioError = error as? IOError, ioError.errnoCode == ECONNREFUSED {
            return String(localized: "the connection was refused")
        }
        return error.localizedDescription
    }
}

enum KafkaClientInfo {
    static let version = "1.0.0"
    static let clientId = "tablepro"
}
