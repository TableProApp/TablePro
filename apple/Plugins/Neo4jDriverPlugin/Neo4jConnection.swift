import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import TableProNeo4jCore
import TableProPluginKit

struct BoltReply: Sendable {
    enum Outcome: Sendable {
        case success([String: PackStreamValue])
        case failure(code: String, message: String)
        case ignored
    }

    var records: [[PackStreamValue]] = []
    var outcome: Outcome = .ignored
}

/// Splits the stream into replies and hands each to the request that is waiting for it. Bolt
/// answers requests in the order they were sent, so a FIFO is the whole routing table.
private final class BoltResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    /// One batch of requests sent in a single flush, answered by one summary each.
    private final class Pending {
        let expected: Int
        var replies: [BoltReply] = []
        var current = BoltReply()
        let continuation: CheckedContinuation<[BoltReply], Error>?

        init(expected: Int, continuation: CheckedContinuation<[BoltReply], Error>?) {
            self.expected = expected
            self.continuation = continuation
        }
    }

    private let lock = NIOLock()
    private var handshake: CheckedContinuation<[UInt8], Error>?
    private var handshakeBytes: [UInt8] = []
    private var handshakeDone = false
    private var pending: [Pending] = []
    private var failure: Error?
    private var dechunker = BoltDechunker()
    private var interrupted = false

    func expectHandshake(_ continuation: CheckedContinuation<[UInt8], Error>) {
        let resolved: Error? = lock.withLock {
            if let failure { return failure }
            handshake = continuation
            return nil
        }
        if let resolved { continuation.resume(throwing: resolved) }
    }

    /// Queues the batch's waiter and writes the batch in the same critical section, so a RESET
    /// sent from `cancel` can never slip between a request and its waiter.
    func dispatch(
        _ requests: [BoltRequest],
        on channel: Channel,
        continuation: CheckedContinuation<[BoltReply], Error>
    ) {
        let expected = requests.filter(\.expectsResponse).count
        let resolved: Error? = lock.withLock {
            if let failure { return failure }
            if expected > 0 {
                pending.append(Pending(expected: expected, continuation: continuation))
            }
            var buffer = channel.allocator.buffer(capacity: 256)
            for request in requests { buffer.writeBytes(request.framed) }
            channel.writeAndFlush(buffer).whenFailure { [weak self] error in
                self?.finish(with: Neo4jError.connectionFailed(error.localizedDescription))
            }
            return nil
        }
        if let resolved {
            continuation.resume(throwing: resolved)
        } else if expected == 0 {
            continuation.resume(returning: [])
        }
    }

    /// Sends RESET only while a request is waiting, so a cancel that lands after the statement
    /// finished cannot interrupt the next one. Its reply has no waiter.
    func interruptInFlight(on channel: Channel) {
        lock.withLock {
            guard failure == nil, !pending.isEmpty else { return }
            interrupted = true
            pending.append(Pending(expected: 1, continuation: nil))
            var buffer = channel.allocator.buffer(capacity: 8)
            buffer.writeBytes(BoltRequest.reset.framed)
            channel.writeAndFlush(buffer, promise: nil)
        }
    }

    /// Whether a cancel sent RESET since the last call. Once that RESET is answered the server
    /// is READY, where a DISCARD for the cancelled stream would fail.
    func takeInterrupted() -> Bool {
        lock.withLock {
            defer { interrupted = false }
            return interrupted
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        var completed: [(Pending, Result<[BoltReply], Error>)] = []
        var handshakeResult: (CheckedContinuation<[UInt8], Error>, [UInt8])?

        lock.withLock {
            if !handshakeDone {
                let needed = 4 - handshakeBytes.count
                handshakeBytes += buffer.readBytes(length: min(needed, buffer.readableBytes)) ?? []
                guard handshakeBytes.count == 4 else { return }
                handshakeDone = true
                if let handshake { handshakeResult = (handshake, handshakeBytes) }
                handshake = nil
            }
            dechunker.append(buffer.readableBytesView)
            do {
                while let message = try dechunker.nextMessage() {
                    guard let head = pending.first else { continue }
                    switch try BoltResponse.decode(message) {
                    case .record(let fields):
                        head.current.records.append(fields)
                        continue
                    case .success(let metadata):
                        head.current.outcome = .success(metadata)
                    case .failure(let code, let message):
                        head.current.outcome = .failure(code: code, message: message)
                    case .ignored:
                        head.current.outcome = .ignored
                    }
                    head.replies.append(head.current)
                    head.current = BoltReply()
                    guard head.replies.count == head.expected else { continue }
                    pending.removeFirst()
                    completed.append((head, .success(head.replies)))
                }
            } catch {
                failure = failure ?? error
                completed += pending.map { ($0, .failure(error)) }
                pending.removeAll()
            }
        }

        if let (continuation, bytes) = handshakeResult { continuation.resume(returning: bytes) }
        for (entry, result) in completed { entry.continuation?.resume(with: result) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(with: Neo4jError.connectionFailed(Neo4jConnection.describe(error)))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(with: Neo4jError.connectionFailed(String(localized: "the server closed the connection")))
    }

    func finish(with error: Error) {
        let (handshake, waiting): (CheckedContinuation<[UInt8], Error>?, [Pending]) = lock.withLock {
            if failure == nil { failure = error }
            defer {
                self.handshake = nil
                pending.removeAll()
            }
            return (self.handshake, pending)
        }
        handshake?.resume(throwing: error)
        for entry in waiting { entry.continuation?.resume(throwing: error) }
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
        if alreadySettled { continuation.resume(throwing: CancellationError()) }
    }

    func deliver(_ channel: Channel) -> Bool {
        guard let waiting = take() else { return false }
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

struct Neo4jCredentials: Sendable {
    let username: String
    let password: String
}

/// One Bolt connection. Statements take turns on it; only `cancel` writes out of turn, because
/// a RESET is how Bolt stops the statement that holds the turn.
actor Neo4jConnection {
    private let host: String
    private let port: Int
    private var channel: Channel?
    private var handler: BoltResponseHandler?
    private var turnIsTaken = false
    private var waitingForTurn: [CheckedContinuation<Void, Never>] = []
    private let wire = NIOLockedValueBox<(Channel, BoltResponseHandler)?>(nil)

    private var opening = false
    private var timedOut = false
    private(set) var version = BoltVersion(major: 0, minor: 0)
    private(set) var serverAgent: String?

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func open(
        ssl: SSLConfiguration,
        credentials: Neo4jCredentials,
        userAgent: String,
        timeout: TimeAmount
    ) async throws {
        guard channel == nil else { return }
        opening = true
        timedOut = false
        defer { opening = false }

        let timeoutNanoseconds = UInt64(max(1, timeout.nanoseconds))
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.abortOpening()
        }
        defer { timeoutTask.cancel() }

        let sslContext = try Self.makeSSLContext(ssl)
        let serverHostname = Self.isIPAddress(host) ? nil : host
        let responseHandler = BoltResponseHandler()
        let bootstrap = ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                do {
                    if let sslContext {
                        let tls = try NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)
                        try channel.pipeline.syncOperations.addHandler(tls)
                    }
                    try channel.pipeline.syncOperations.addHandler(responseHandler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let connected: Channel
        do {
            connected = try await Self.connect(bootstrap, host: host, port: port)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Neo4jError.connectionFailed(Self.describe(error))
        }
        guard !timedOut else {
            connected.close(promise: nil)
            throw Self.timeoutError
        }
        channel = connected
        handler = responseHandler
        wire.withLockedValue { $0 = (connected, responseHandler) }

        do {
            try await negotiate(on: connected, handler: responseHandler, usesTLS: ssl.isEnabled)
            try await authenticate(credentials, userAgent: userAgent)
        } catch {
            await close()
            throw timedOut ? Self.timeoutError : error
        }
    }

    private func negotiate(on channel: Channel, handler: BoltResponseHandler, usesTLS: Bool) async throws {
        let bytes: [UInt8]
        do {
            bytes = try await withCheckedThrowingContinuation { continuation in
                handler.expectHandshake(continuation)
                var buffer = channel.allocator.buffer(capacity: 20)
                buffer.writeBytes(BoltHandshake.request)
                channel.writeAndFlush(buffer, promise: nil)
            }
        } catch {
            guard !usesTLS else { throw error }
            throw Neo4jError.connectionFailed(String(
                format: String(localized: "%@ during the Bolt handshake. If the server requires TLS, turn on SSL."),
                Self.describe(error)
            ))
        }
        if bytes == Array("HTTP".utf8) {
            throw Neo4jError.connectionFailed(String(localized: "this port speaks HTTP; use the Bolt port, usually 7687"))
        }
        guard let negotiated = BoltHandshake.version(fromResponse: bytes) else {
            throw Neo4jError.connectionFailed(BoltProtocolError.unsupportedServer.localizedDescription)
        }
        version = negotiated
    }

    private func authenticate(_ credentials: Neo4jCredentials, userAgent: String) async throws {
        var hello: [String: PackStreamValue] = ["user_agent": .string(userAgent)]
        if version.sendsBoltAgent {
            hello["bolt_agent"] = .map(["product": .string(userAgent)])
        }
        let auth: [String: PackStreamValue] = credentials.username.isEmpty
            ? ["scheme": .string("none")]
            : [
                "scheme": .string("basic"),
                "principal": .string(credentials.username),
                "credentials": .string(credentials.password)
            ]
        let requests: [BoltRequest]
        if version.separatesLogon {
            requests = [.hello(extra: hello), .logon(auth: auth)]
        } else {
            requests = [.hello(extra: hello.merging(auth) { current, _ in current })]
        }
        let replies = try await send(requests)
        if case .success(let metadata) = replies.first?.outcome {
            serverAgent = metadata["server"]?.stringValue
        }
        if let failure = replies.lazy.compactMap(Neo4jError.init(reply:)).first {
            throw failure
        }
    }

    /// Writes the requests in one flush and waits for every reply. A failure leaves the server
    /// ignoring everything until a RESET, so the turn is not handed on before one is answered.
    /// When the last reply has more records, the rest are discarded in the same turn and the
    /// DISCARD reply is appended: it carries the statement's final summary.
    func send(_ requests: [BoltRequest]) async throws -> [BoltReply] {
        await claimTurn()
        defer { releaseTurn() }
        guard let channel, let handler, channel.isActive else { throw Neo4jError.notConnected }
        try Task.checkCancellation()

        _ = handler.takeInterrupted()
        var replies = try await Self.exchange(requests, channel: channel, handler: handler)
        let cancelled = handler.takeInterrupted()
        if !Self.allSucceeded(replies) {
            if !cancelled { _ = try? await Self.exchange([.reset], channel: channel, handler: handler) }
        } else if !cancelled, case .success(let summary) = replies.last?.outcome, summary["has_more"]?.boolValue == true {
            do {
                let discarded = try await Self.exchange([.discard], channel: channel, handler: handler)
                replies += discarded
                if !Self.allSucceeded(discarded) {
                    _ = try? await Self.exchange([.reset], channel: channel, handler: handler)
                }
            } catch {
                _ = try? await Self.exchange([.reset], channel: channel, handler: handler)
                throw error
            }
        }
        return replies
    }

    private static func allSucceeded(_ replies: [BoltReply]) -> Bool {
        replies.allSatisfy { if case .success = $0.outcome { true } else { false } }
    }

    private static func exchange(
        _ requests: [BoltRequest],
        channel: Channel,
        handler: BoltResponseHandler
    ) async throws -> [BoltReply] {
        try await withCheckedThrowingContinuation { continuation in
            handler.dispatch(requests, on: channel, continuation: continuation)
        }
    }

    /// Stops the running statement. Bolt fails the statement with an IGNORED or FAILURE reply and
    /// answers the RESET once it has.
    nonisolated func cancel() {
        guard let (channel, handler) = wire.withLockedValue({ $0 }), channel.isActive else { return }
        handler.interruptInFlight(on: channel)
    }

    func close() async {
        let existing = channel
        if let existing, existing.isActive {
            var buffer = existing.allocator.buffer(capacity: 8)
            buffer.writeBytes(BoltRequest.goodbye.framed)
            existing.writeAndFlush(buffer, promise: nil)
        }
        handler?.finish(with: Neo4jError.notConnected)
        channel = nil
        handler = nil
        wire.withLockedValue { $0 = nil }
        guard let existing else { return }
        try? await existing.close()
    }

    private static let timeoutError = Neo4jError.connectionFailed(String(localized: "the connection timed out"))

    /// Only an `open` still in progress is aborted: a timer that fires as `open` returns must
    /// not close the connection it just handed over.
    private func abortOpening() async {
        guard opening else { return }
        timedOut = true
        handler?.finish(with: Self.timeoutError)
        await close()
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    var isOpen: Bool { channel?.isActive == true }

    private func claimTurn() async {
        guard turnIsTaken else {
            turnIsTaken = true
            return
        }
        await withCheckedContinuation { waitingForTurn.append($0) }
    }

    private func releaseTurn() {
        guard !waitingForTurn.isEmpty else {
            turnIsTaken = false
            return
        }
        waitingForTurn.removeFirst().resume()
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

    private static func makeSSLContext(_ ssl: SSLConfiguration) throws -> NIOSSLContext? {
        guard ssl.isEnabled else { return nil }
        var configuration = TLSConfiguration.makeClientConfiguration()
        switch ssl.mode {
        case .verifyIdentity: configuration.certificateVerification = .fullVerification
        case .verifyCa: configuration.certificateVerification = .noHostnameVerification
        default: configuration.certificateVerification = .none
        }
        do {
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
        } catch {
            throw Neo4jError.connectionFailed(describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        if let tlsError = error as? NIOSSLError {
            switch tlsError {
            case .handshakeFailed:
                return String(localized: "the TLS handshake failed")
            case .failedToLoadCertificate:
                return String(localized: "the certificate file could not be read")
            case .failedToLoadPrivateKey:
                return String(localized: "the private key file could not be read")
            default:
                return String(describing: tlsError)
            }
        }
        if let tlsError = error as? NIOSSLExtraError, tlsError == .failedToValidateHostname {
            return String(localized: "the server's certificate does not cover the hostname you connected to")
        }
        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
            return String(localized: "the connection timed out")
        }
        if let connectError = error as? NIOConnectionError, let first = connectError.connectionErrors.first {
            return describe(first.error)
        }
        if let ioError = error as? IOError {
            if ioError.errnoCode == ECONNREFUSED { return String(localized: "the connection was refused") }
            return String(cString: strerror(ioError.errnoCode))
        }
        if let neo4jError = error as? Neo4jError, case .connectionFailed(let detail) = neo4jError {
            return detail
        }
        return error.localizedDescription
    }
}
