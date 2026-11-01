import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import os
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

    var metadata: [String: PackStreamValue] {
        if case .success(let metadata) = outcome { return metadata }
        return [:]
    }

    var hasMore: Bool { metadata["has_more"]?.boolValue == true }
}

struct BoltResult: Sendable {
    let keys: [String]
    let records: [[PackStreamValue]]
    let summary: [String: PackStreamValue]
    let hasMore: Bool
}

struct Neo4jCredentials: Sendable {
    let username: String
    let password: String
}

// Bolt answers requests in the order they were sent, so a FIFO of waiters is the whole routing table.
private final class BoltResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private final class Pending {
        let expected: Int
        let interruptible: Bool
        let continuation: CheckedContinuation<[BoltReply], Error>?
        var replies: [BoltReply] = []
        var current = BoltReply()

        init(expected: Int, interruptible: Bool, continuation: CheckedContinuation<[BoltReply], Error>?) {
            self.expected = expected
            self.interruptible = interruptible
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
    private var cancels = 0
    private var interrupted = false

    var cancelCount: Int { lock.withLock { cancels } }

    func expectHandshake(_ continuation: CheckedContinuation<[UInt8], Error>) {
        let resolved: Error? = lock.withLock {
            if let failure { return failure }
            handshake = continuation
            return nil
        }
        if let resolved { continuation.resume(throwing: resolved) }
    }

    // Queued and written under one lock, so a RESET from `interrupt` never lands between a batch and its waiter.
    // A user statement passes the cancel count it saw when it queued for the connection; a cancel since then
    // stops it before it is sent.
    func dispatch(
        _ requests: [BoltRequest],
        cancellableSince: Int?,
        on channel: Channel,
        continuation: CheckedContinuation<[BoltReply], Error>
    ) {
        let expected = requests.filter(\.expectsResponse).count
        let refusal: Error? = lock.withLock {
            if let failure { return failure }
            if let cancellableSince, cancellableSince != cancels { return Neo4jError.cancelled }
            if expected > 0 {
                pending.append(Pending(
                    expected: expected, interruptible: cancellableSince != nil, continuation: continuation
                ))
            }
            var buffer = channel.allocator.buffer(capacity: 256)
            for request in requests { buffer.writeBytes(request.framed) }
            channel.writeAndFlush(buffer).whenFailure { [weak self] error in
                self?.finish(with: Neo4jError.connectionFailed(PluginNIOChannel.describe(error)))
            }
            return nil
        }
        if let refusal {
            continuation.resume(throwing: refusal)
        } else if expected == 0 {
            continuation.resume(returning: [])
        }
    }

    // RESET goes out only while a user statement is on the wire, never to metadata work holding the connection.
    func interrupt(on channel: Channel) {
        lock.withLock {
            cancels += 1
            guard failure == nil, pending.contains(where: \.interruptible) else { return }
            interrupted = true
            pending.append(Pending(expected: 1, interruptible: false, continuation: nil))
            var buffer = channel.allocator.buffer(capacity: 8)
            buffer.writeBytes(BoltRequest.reset.framed)
            channel.writeAndFlush(buffer, promise: nil)
        }
    }

    // Once an interrupting RESET is answered the server is READY, where the turn's own RESET or DISCARD would fail.
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
        finish(with: Neo4jError.connectionFailed(PluginNIOChannel.describe(error)))
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

// Statements take turns on the one Bolt connection; only `cancel` writes out of turn.
actor Neo4jConnection {
    private struct Wire {
        let channel: Channel
        let handler: BoltResponseHandler
    }

    private static let timeoutError = Neo4jError.connectionFailed(String(localized: "the connection timed out"))
    private static let logger = Logger(subsystem: "com.TablePro", category: "Neo4jConnection")

    private let host: String
    private let port: Int
    private let wire = NIOLockedValueBox<Wire?>(nil)
    private var turnIsTaken = false
    private var waitingForTurn: [CheckedContinuation<Void, Never>] = []
    private var opening = false
    private var timedOut = false
    private(set) var version = BoltVersion(major: 0, minor: 0)
    private(set) var serverAgent: String?

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func open(ssl: SSLConfiguration, credentials: Neo4jCredentials, userAgent: String, timeout: TimeAmount) async throws {
        guard wire.withLockedValue({ $0 }) == nil else { return }
        opening = true
        timedOut = false
        defer { opening = false }

        let timeoutNanoseconds = UInt64(max(1, timeout.nanoseconds))
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            await self?.abortOpening()
        }
        defer { timeoutTask.cancel() }

        do {
            if ssl.mode == .preferred {
                do {
                    try await dial(ssl: ssl, timeout: timeout)
                } catch let error where !(error is CancellationError) && !timedOut {
                    let reason = error.localizedDescription
                    Self.logger.info("TLS failed under SSL Preferred, retrying without it: \(reason, privacy: .public)")
                    var plain = ssl
                    plain.mode = .disabled
                    try await dial(ssl: plain, timeout: timeout)
                }
            } else {
                try await dial(ssl: ssl, timeout: timeout)
            }
            try await authenticate(credentials, userAgent: userAgent)
        } catch {
            await close()
            throw timedOut ? Self.timeoutError : error
        }
    }

    private func dial(ssl: SSLConfiguration, timeout: TimeAmount) async throws {
        let sslContext: NIOSSLContext?
        do {
            sslContext = try PluginNIOChannel.tlsContext(for: ssl)
        } catch {
            throw Neo4jError.connectionFailed(PluginNIOChannel.describe(error))
        }
        // NIOSSL refuses an IP address as SNI; Aura routes on SNI, so a hostname always sends it.
        let serverHostname = Self.isIPAddress(host) ? nil : host
        let handler = BoltResponseHandler()
        let bootstrap = ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                do {
                    if let sslContext {
                        let tls = try NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)
                        try channel.pipeline.syncOperations.addHandler(tls)
                    }
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: Channel
        do {
            channel = try await PluginNIOChannel.connect(bootstrap, host: host, port: port)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Neo4jError.connectionFailed(PluginNIOChannel.describe(error))
        }
        guard !timedOut else {
            channel.close(promise: nil)
            throw Self.timeoutError
        }
        wire.withLockedValue { $0 = Wire(channel: channel, handler: handler) }
        do {
            try await negotiate(on: channel, handler: handler, usesTLS: ssl.isEnabled)
        } catch {
            await close()
            throw error
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
            guard !usesTLS, !timedOut else { throw error }
            throw Neo4jError.connectionFailed(String(
                format: String(localized: "%@ during the Bolt handshake. If the server requires TLS, turn on SSL."),
                Neo4jError.detail(of: error)
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
        let requests: [BoltRequest] = version.separatesLogon
            ? [.hello(extra: hello), .logon(auth: auth)]
            : [.hello(extra: hello.merging(auth) { current, _ in current })]
        let replies = try await withTurn(interruptible: false) { wire, _ in
            try await Self.exchange(requests, on: wire, cancellableSince: nil)
        }
        serverAgent = replies.first?.metadata["server"]?.stringValue
        try Self.requireSuccess(replies)
    }

    // RUN and one PULL of `pull` records (-1 for all); records left on the server are discarded in the same turn,
    // and the DISCARD's summary is the statement's.
    func run(_ statement: BoltRequest, pull: Int64, interruptible: Bool) async throws -> BoltResult {
        try await withTurn(interruptible: interruptible) { wire, since in
            let replies = try await Self.exchange([statement, .pull(count: pull)], on: wire, cancellableSince: since)
            try Self.requireSuccess(replies)
            guard replies.count == 2 else { throw Neo4jError.notConnected }
            var summary = replies[1].metadata
            if replies[1].hasMore {
                let discarded = try await Self.exchange([.discard], on: wire, cancellableSince: since)
                try Self.requireSuccess(discarded)
                summary = discarded.first?.metadata ?? summary
            }
            return BoltResult(
                keys: Self.keys(of: replies[0]),
                records: replies[1].records,
                summary: summary,
                hasMore: replies[1].hasMore
            )
        }
    }

    // RUN, then PULL `batchSize` records at a time and hand each batch to `receive` until it returns false, the task
    // is cancelled or the server has no more. The first call always comes, with the keys, even for no records.
    func stream(
        _ statement: BoltRequest,
        batchSize: Int64,
        interruptible: Bool,
        receive: @Sendable (_ keys: [String], _ records: [[PackStreamValue]], _ isFirst: Bool) -> Bool
    ) async throws {
        try await withTurn(interruptible: interruptible) { wire, since in
            let replies = try await Self.exchange([statement, .pull(count: batchSize)], on: wire, cancellableSince: since)
            try Self.requireSuccess(replies)
            guard replies.count == 2 else { throw Neo4jError.notConnected }
            let keys = Self.keys(of: replies[0])
            var batch = replies[1]
            var isFirst = true
            while true {
                let wanted = receive(keys, batch.records, isFirst)
                isFirst = false
                guard batch.hasMore else { return }
                guard wanted, !Task.isCancelled else {
                    try Self.requireSuccess(try await Self.exchange([.discard], on: wire, cancellableSince: since))
                    return
                }
                let next = try await Self.exchange([.pull(count: batchSize)], on: wire, cancellableSince: since)
                try Self.requireSuccess(next)
                guard let reply = next.first else { throw Neo4jError.notConnected }
                batch = reply
            }
        }
    }

    // The cancel count is read before queueing, so a cancel while the statement waits for its turn still stops it.
    // A failure leaves the server ignoring everything until a RESET, so one is answered before the turn moves on.
    private func withTurn<T: Sendable>(
        interruptible: Bool,
        _ body: (Wire, Int?) async throws -> T
    ) async throws -> T {
        let since = interruptible ? wire.withLockedValue({ $0 })?.handler.cancelCount : nil
        await claimTurn()
        defer { releaseTurn() }
        guard let current = wire.withLockedValue({ $0 }), current.channel.isActive else { throw Neo4jError.notConnected }
        try Task.checkCancellation()
        _ = current.handler.takeInterrupted()
        do {
            return try await body(current, since)
        } catch {
            if !current.handler.takeInterrupted() {
                _ = try? await Self.exchange([.reset], on: current, cancellableSince: nil)
            }
            throw error
        }
    }

    private static func exchange(
        _ requests: [BoltRequest],
        on wire: Wire,
        cancellableSince: Int?
    ) async throws -> [BoltReply] {
        try await withCheckedThrowingContinuation { continuation in
            wire.handler.dispatch(requests, cancellableSince: cancellableSince, on: wire.channel, continuation: continuation)
        }
    }

    private static func requireSuccess(_ replies: [BoltReply]) throws {
        if let error = replies.lazy.compactMap(Neo4jError.init(reply:)).first { throw error }
    }

    private static func keys(of reply: BoltReply) -> [String] {
        reply.metadata["fields"]?.listValue?.compactMap(\.stringValue) ?? []
    }

    nonisolated func cancel() {
        guard let current = wire.withLockedValue({ $0 }), current.channel.isActive else { return }
        current.handler.interrupt(on: current.channel)
    }

    func close() async {
        let existing = wire.withLockedValue { current -> Wire? in
            defer { current = nil }
            return current
        }
        guard let existing else { return }
        if existing.channel.isActive {
            var buffer = existing.channel.allocator.buffer(capacity: 8)
            buffer.writeBytes(BoltRequest.goodbye.framed)
            existing.channel.writeAndFlush(buffer, promise: nil)
        }
        existing.handler.finish(with: Neo4jError.notConnected)
        try? await existing.channel.close()
    }

    // Only an open still in progress is aborted: a timer firing as `open` returns must not close what it handed over.
    private func abortOpening() async {
        guard opening else { return }
        timedOut = true
        wire.withLockedValue { $0 }?.handler.finish(with: Self.timeoutError)
        await close()
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

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
}
