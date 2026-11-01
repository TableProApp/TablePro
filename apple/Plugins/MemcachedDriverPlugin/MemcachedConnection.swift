import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import TableProMemcachedCore
import TableProPluginKit

/// Feeds the bytes of the one request in flight into its reader and resumes the caller once the reply is whole.
/// Every path that resumes goes through the lock and clears the continuation first, so it resumes once.
private final class MemcachedReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var reader: MemcachedReplyReader?
    private var continuation: CheckedContinuation<MemcachedReply, Error>?
    private var failure: Error?
    private let lock = NIOLock()

    func expect(
        _ shape: MemcachedReplyShape,
        lineLimit: Int,
        continuation: CheckedContinuation<MemcachedReply, Error>
    ) -> Bool {
        let refusal: Error? = lock.withLock {
            if let failure { return failure }
            reader = MemcachedReplyReader(shape: shape, lineLimit: lineLimit)
            self.continuation = continuation
            return nil
        }
        guard let refusal else { return true }
        continuation.resume(throwing: refusal)
        return false
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let outcome: (CheckedContinuation<MemcachedReply, Error>, Result<MemcachedReply, Error>)? = lock.withLock {
            guard continuation != nil else { return nil }
            reader?.append(buffer.readableBytesView)
            let result: Result<MemcachedReply, Error>
            do {
                guard let reply = try reader?.reply() else { return nil }
                result = .success(reply)
            } catch {
                result = .failure(error)
            }
            defer { continuation = nil; reader = nil }
            return continuation.map { ($0, result) }
        }
        guard let (waiting, result) = outcome else { return }
        waiting.resume(with: result)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(with: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(with: MemcachedError.connectionClosed)
    }

    func finish(with error: Error) {
        let waiting = lock.withLock { () -> CheckedContinuation<MemcachedReply, Error>? in
            if failure == nil { failure = error }
            defer { continuation = nil; reader = nil }
            return continuation
        }
        waiting?.resume(throwing: error)
    }
}

/// Resumes a connect's caller once, whichever of the connect and the cancellation arrives first.
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
        if alreadySettled { continuation.resume(throwing: CancellationError()) }
    }

    func deliver(_ channel: Channel) -> Bool {
        guard let waiting = take() else { return false }
        waiting.resume(returning: channel)
        return true
    }

    func fail(_ error: Error) { take()?.resume(throwing: error) }
    func cancel() { take()?.resume(throwing: CancellationError()) }

    private func take() -> CheckedContinuation<Channel, Error>? {
        lock.withLock {
            guard !settled else { return nil }
            settled = true
            defer { continuation = nil }
            return continuation
        }
    }
}

struct MemcachedEndpoint: Sendable {
    let host: String
    let port: Int
    let ssl: SSLConfiguration
    let username: String
    let password: String
    let connectTimeout: TimeAmount
}

/// One TCP connection speaking the text protocol, one request at a time. The text protocol has no request ids,
/// so replies are matched to requests by order alone, and a queue keeps two callers from interleaving.
actor MemcachedConnection {
    private let endpoint: MemcachedEndpoint
    private var channel: Channel?
    private var handler: MemcachedReplyHandler?
    private var wireSlotIsTaken = false
    private var waitingForWireSlot: [CheckedContinuation<Void, Never>] = []
    private var requestTimeout: TimeAmount?

    /// A reply that has not finished by then closes the connection, since the text protocol cannot skip it.
    func setRequestTimeout(seconds: Int) {
        requestTimeout = seconds > 0 ? .seconds(Int64(seconds)) : nil
    }

    init(endpoint: MemcachedEndpoint) {
        self.endpoint = endpoint
    }

    func open() async throws {
        guard channel == nil else { return }
        let sslContext = try Self.makeSSLContext(endpoint.ssl)
        let serverHostname = endpoint.ssl.verifiesHostname ? endpoint.host : nil
        let replyHandler = MemcachedReplyHandler()
        let bootstrap = ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connectTimeout(endpoint.connectTimeout)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                do {
                    if let sslContext {
                        let tls = try NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)
                        try channel.pipeline.syncOperations.addHandler(tls)
                    }
                    try channel.pipeline.syncOperations.addHandler(replyHandler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        do {
            channel = try await Self.connect(bootstrap, host: endpoint.host, port: endpoint.port)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MemcachedError.connectFailed(Self.describeConnect(error))
        }
        handler = replyHandler

        do {
            try await authenticate()
        } catch {
            await close()
            throw error
        }
    }

    /// A server started with `-Y <auth file>` refuses every command until a `set` carries the user and password.
    /// Any other server would store them as an ordinary item, so they are sent only after a refusal.
    private func authenticate() async throws {
        do {
            _ = try await send(.version)
            return
        } catch let error as MemcachedServerError where error.needsAuthentication {
            guard !endpoint.username.isEmpty else { throw MemcachedError.authenticationRequired }
        }
        let login = MemcachedCommand.store(
            .set, key: "tablepro", flags: 0, exptime: 0, value: Data("\(endpoint.username) \(endpoint.password)".utf8)
        )
        do {
            guard case .status("STORED") = try await send(login) else { throw MemcachedError.authenticationFailed }
        } catch let error as MemcachedServerError where error.kind == .clientError {
            throw MemcachedError.authenticationFailed
        }
    }

    private static func connect(_ bootstrap: ClientBootstrap, host: String, port: Int) async throws -> Channel {
        let gate = ConnectGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.arm(continuation)
                bootstrap.connect(host: host, port: port).whenComplete { result in
                    switch result {
                    case .success(let channel):
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
        handler?.finish(with: MemcachedError.notConnected)
        channel = nil
        handler = nil
        try? await existing?.close()
    }

    var isOpen: Bool { channel?.isActive == true }

    /// Sends one command and reads its reply. Cancelling closes the channel: once a request is written the text
    /// protocol has no way to skip its reply, so the connection cannot be reused for the next one.
    func send(_ command: MemcachedCommand, lineLimit: Int = 1_000_000) async throws -> MemcachedReply {
        await claimWireSlot()
        defer { releaseWireSlot() }

        guard let channel, let handler, channel.isActive else { throw MemcachedError.notConnected }
        try Task.checkCancellation()

        let bytes = command.wireBytes
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        let deadline = requestTimeout.map { timeout in
            channel.eventLoop.scheduleTask(in: timeout) {
                handler.finish(with: MemcachedError.timedOut)
                channel.close(promise: nil)
            }
        }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard handler.expect(command.replyShape, lineLimit: lineLimit, continuation: continuation) else { return }
                channel.writeAndFlush(buffer).whenFailure { error in
                    handler.finish(with: MemcachedError.connectFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            channel.close(promise: nil)
        }
    }

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

    private static func makeSSLContext(_ ssl: SSLConfiguration) throws -> NIOSSLContext? {
        guard ssl.isEnabled else { return nil }
        var configuration = TLSConfiguration.makeClientConfiguration()
        switch ssl.mode {
        case .verifyIdentity: configuration.certificateVerification = .fullVerification
        case .verifyCa: configuration.certificateVerification = .noHostnameVerification
        default: configuration.certificateVerification = .none
        }
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

    private static func describeConnect(_ error: Error) -> String {
        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            return String(localized: "the connection timed out")
        }
        if let ioError = error as? IOError, ioError.errnoCode == ECONNREFUSED {
            return String(localized: "the connection was refused")
        }
        if error is NIOSSLError || error is NIOSSLExtraError {
            return String(localized: "the TLS handshake failed")
        }
        return error.localizedDescription
    }
}
