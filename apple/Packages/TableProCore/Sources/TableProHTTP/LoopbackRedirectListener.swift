import Darwin
import Foundation
import Network
import os

public enum LoopbackRedirectListenerError: Error, Equatable, Sendable {
    case portInUse
    case timedOut
}

public enum LoopbackRedirectAnswer<Outcome: Sendable>: Sendable {
    case ignore(Data)
    case settle(Data, Result<Outcome, any Error>)
}

// Waits on loopback for one browser redirect (RFC 8252 section 7.3). `answer` sees each complete request head;
// a request it ignores gets its reply and changes nothing, so a page probing the port cannot end the wait.
public final class LoopbackRedirectListener<Outcome: Sendable>: @unchecked Sendable {
    public typealias Answer = @Sendable (_ requestHead: Data) -> LoopbackRedirectAnswer<Outcome>

    private struct Admission {
        let connection: NWConnection
        let order: UInt64
        var awaitingHead: Bool
    }

    private struct Teardown {
        let listener: NWListener?
        let connections: [NWConnection]
        let ipv6Hold: Int32
        let readyContinuation: CheckedContinuation<UInt16, any Error>?
        let readyTimeout: DispatchWorkItem?
        let outcomeContinuation: CheckedContinuation<Outcome, any Error>?
        let outcomeTimeout: DispatchWorkItem?
    }

    private let port: UInt16
    private let headTimeout: TimeInterval
    private let answer: Answer
    private let holdIPv6: @Sendable (UInt16) -> LoopbackPortHold
    private let queue = DispatchQueue(label: "com.TablePro.LoopbackRedirectListener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var ipv6Hold: Int32 = -1
    private var portAttempts = 1
    private var connections: [ObjectIdentifier: Admission] = [:]
    private var admissions: UInt64 = 0
    private var readyContinuation: CheckedContinuation<UInt16, any Error>?
    private var readyTimeout: DispatchWorkItem?
    private var outcomeContinuation: CheckedContinuation<Outcome, any Error>?
    private var outcomeTimeout: DispatchWorkItem?
    private var settled: Result<Outcome, any Error>?

    // Port 0 lets the kernel pick one.
    public convenience init(port: UInt16, headTimeout: TimeInterval = 5, answer: @escaping Answer) {
        self.init(port: port, headTimeout: headTimeout, holdIPv6: { LoopbackPortHold.ipv6(port: $0) }, answer: answer)
    }

    init(
        port: UInt16,
        headTimeout: TimeInterval,
        holdIPv6: @escaping @Sendable (UInt16) -> LoopbackPortHold,
        answer: @escaping Answer
    ) {
        self.port = port
        self.headTimeout = headTimeout
        self.holdIPv6 = holdIPv6
        self.answer = answer
    }

    @discardableResult
    public func start(readyTimeout: TimeInterval = 10) async throws -> UInt16 {
        let listener: NWListener
        do {
            listener = try makeListener()
        } catch {
            LoopbackRedirectLimits.logger.error("Could not create the loopback redirect listener")
            throw LoopbackRedirectListenerError.portInUse
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let refusal = lock.withLock { () -> (any Error)? in
                if let settled {
                    guard case .failure(let error) = settled else { return CancellationError() }
                    return error
                }
                self.listener = listener
                readyContinuation = continuation
                let item = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(LoopbackRedirectListenerError.timedOut))
                }
                self.readyTimeout = item
                queue.asyncAfter(deadline: .now() + readyTimeout, execute: item)
                return nil
            }
            guard let refusal else {
                listener.start(queue: queue)
                return
            }
            listener.cancel()
            continuation.resume(throwing: refusal)
        }
    }

    public func outcome(timeout: TimeInterval, timeoutError: any Error) async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, any Error>) in
                let early = lock.withLock { () -> Result<Outcome, any Error>? in
                    if let settled { return settled }
                    outcomeContinuation = continuation
                    let item = DispatchWorkItem { [weak self] in
                        self?.finish(.failure(timeoutError))
                    }
                    outcomeTimeout = item
                    queue.asyncAfter(deadline: .now() + timeout, execute: item)
                    return nil
                }
                if let early {
                    continuation.resume(with: early)
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    public func stop() {
        finish(.failure(CancellationError()))
    }

    private func makeListener() throws -> NWListener {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LoopbackRedirectListenerError.portInUse
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let listener else { return }
            self?.listenerChanged(state, of: listener)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        return listener
    }

    private func listenerChanged(_ state: NWListener.State, of source: NWListener) {
        // A listener given up for another kernel port reports its own cancellation; that ends nothing.
        let isCurrent = lock.withLock { listener === source }
        guard isCurrent else { return }
        switch state {
        case .ready:
            let awaitingReady = lock.withLock { readyContinuation != nil }
            guard awaitingReady else { return }
            guard let port = source.port?.rawValue, port > 0 else {
                finish(.failure(LoopbackRedirectListenerError.portInUse))
                return
            }
            holdIPv6Loopback(port: port)
        case .failed(let error), .waiting(let error):
            LoopbackRedirectLimits.logger.error(
                "The loopback redirect listener failed (\(LoopbackRedirectLimits.code(of: error), privacy: .public))"
            )
            finish(.failure(LoopbackRedirectListenerError.portInUse))
        default:
            break
        }
    }

    // A redirect to localhost may come in over ::1, so no other process may take that port (RFC 8252 section 8.3).
    private func holdIPv6Loopback(port bound: UInt16) {
        switch holdIPv6(bound) {
        case .held(let descriptor):
            let kept = lock.withLock { () -> Bool in
                guard settled == nil else { return false }
                ipv6Hold = descriptor
                return true
            }
            guard kept else {
                close(descriptor)
                return
            }
            resumeReady(bound)
        case .unavailable:
            resumeReady(bound)
        case .taken(let code):
            // A port the kernel picked is only a bad draw; a fixed redirect port has no alternative.
            if port == 0, listenOnAnotherKernelPort() { return }
            LoopbackRedirectLimits.logger.error("Another process holds the IPv6 loopback port (errno \(code, privacy: .public))")
            finish(.failure(LoopbackRedirectListenerError.portInUse))
        }
    }

    private func listenOnAnotherKernelPort() -> Bool {
        guard let replacement = try? makeListener() else { return false }
        let (swapped, previous) = lock.withLock { () -> (Bool, NWListener?) in
            guard settled == nil, readyContinuation != nil,
                  portAttempts < LoopbackRedirectLimits.maximumKernelPortAttempts
            else { return (false, nil) }
            portAttempts += 1
            let previous = listener
            listener = replacement
            return (true, previous)
        }
        guard swapped else {
            replacement.cancel()
            return false
        }
        previous?.cancel()
        replacement.start(queue: queue)
        return true
    }

    private func resumeReady(_ port: UInt16) {
        let (continuation, item) = lock.withLock { () -> (CheckedContinuation<UInt16, any Error>?, DispatchWorkItem?) in
            let pending = (readyContinuation, readyTimeout)
            readyContinuation = nil
            readyTimeout = nil
            return pending
        }
        item?.cancel()
        continuation?.resume(returning: port)
    }

    // When every slot is taken, the oldest connection that never sent its request makes room for the new one.
    private func accept(_ connection: NWConnection) {
        let (admitted, evicted) = lock.withLock { () -> (Bool, NWConnection?) in
            guard settled == nil else { return (false, nil) }
            var evicted: NWConnection?
            if connections.count >= LoopbackRedirectLimits.maximumConnections {
                let idle = connections.filter { $0.value.awaitingHead }
                guard let oldest = idle.min(by: { $0.value.order < $1.value.order }) else { return (false, nil) }
                connections[oldest.key] = nil
                evicted = oldest.value.connection
            }
            admissions += 1
            connections[ObjectIdentifier(connection)] = Admission(connection: connection, order: admissions, awaitingHead: true)
            return (true, evicted)
        }
        evicted?.cancel()
        guard admitted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled:
                self?.release(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, head: Data())
        queue.asyncAfter(deadline: .now() + headTimeout) { [weak self, weak connection] in
            guard let self, let connection, self.dropIfAwaitingHead(connection) else { return }
            connection.cancel()
        }
    }

    private func receive(on connection: NWConnection, head: Data) {
        let remaining = LoopbackRedirectLimits.maximumRequestHeadBytes - head.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var received = head
            if let content {
                received.append(content)
            }
            if error != nil, received.isEmpty {
                connection.cancel()
                return
            }
            let hasFullHead = LoopbackRedirectRequest.isComplete(received)
            if error == nil, !isComplete, !hasFullHead, received.count < LoopbackRedirectLimits.maximumRequestHeadBytes {
                self.receive(on: connection, head: received)
                return
            }
            self.respond(on: connection, head: received)
        }
    }

    private func respond(on connection: NWConnection, head: Data) {
        switch answer(head) {
        case .ignore(let response):
            markAnswered(connection)
            send(response, on: connection)
        case .settle(let response, let result):
            release(connection)
            send(response, on: connection)
            finish(result)
        }
    }

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func markAnswered(_ connection: NWConnection) {
        lock.withLock {
            connections[ObjectIdentifier(connection)]?.awaitingHead = false
            return
        }
    }

    private func dropIfAwaitingHead(_ connection: NWConnection) -> Bool {
        lock.withLock { () -> Bool in
            let key = ObjectIdentifier(connection)
            guard connections[key]?.awaitingHead == true else { return false }
            connections[key] = nil
            return true
        }
    }

    private func release(_ connection: NWConnection) {
        lock.withLock {
            connections[ObjectIdentifier(connection)] = nil
        }
    }

    private func finish(_ result: Result<Outcome, any Error>) {
        let teardown = lock.withLock { () -> Teardown? in
            guard settled == nil else { return nil }
            settled = result
            let teardown = Teardown(
                listener: listener,
                connections: connections.values.map { $0.connection },
                ipv6Hold: ipv6Hold,
                readyContinuation: readyContinuation,
                readyTimeout: readyTimeout,
                outcomeContinuation: outcomeContinuation,
                outcomeTimeout: outcomeTimeout
            )
            listener = nil
            connections = [:]
            ipv6Hold = -1
            readyContinuation = nil
            readyTimeout = nil
            outcomeContinuation = nil
            outcomeTimeout = nil
            return teardown
        }
        guard let teardown else { return }
        teardown.readyTimeout?.cancel()
        teardown.outcomeTimeout?.cancel()
        teardown.listener?.cancel()
        teardown.connections.forEach { $0.cancel() }
        if teardown.ipv6Hold >= 0 {
            close(teardown.ipv6Hold)
        }
        if let ready = teardown.readyContinuation {
            switch result {
            case .failure(let error):
                ready.resume(throwing: error)
            case .success:
                ready.resume(throwing: CancellationError())
            }
        }
        teardown.outcomeContinuation?.resume(with: result)
    }
}

public enum LoopbackRedirectRequest {
    public static func isComplete(_ head: Data) -> Bool {
        head.range(of: Data("\r\n\r\n".utf8)) != nil || head.range(of: Data("\n\n".utf8)) != nil
    }

    public static func text(of head: Data) -> String {
        String(bytes: head, encoding: .utf8) ?? String(bytes: head, encoding: .isoLatin1) ?? ""
    }

    // The target of a `GET` in origin form, the only shape a browser sends for a redirect.
    public static func getTarget(_ head: String) -> String? {
        let scalars = head.unicodeScalars
        let lineEnd = scalars.firstIndex(of: "\n") ?? scalars.endIndex
        var requestLine = String(scalars[scalars.startIndex..<lineEnd])
        if requestLine.unicodeScalars.last == "\r" {
            requestLine.unicodeScalars.removeLast()
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/"), parts[1].hasPrefix("/") else {
            return nil
        }
        return String(parts[1])
    }

    public static func singleValue(named name: String, in items: [URLQueryItem]) -> String? {
        let matches = items.filter { $0.name == name }
        guard matches.count == 1 else { return nil }
        return matches[0].value
    }

    // A redirect query is form encoded, so "+" stands for a space.
    public static func formDecodedItems(in components: URLComponents) -> [URLQueryItem] {
        (components.percentEncodedQueryItems ?? []).map { item in
            URLQueryItem(name: formDecoded(item.name), value: item.value.map(formDecoded))
        }
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private static func formDecoded(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

public enum LoopbackRedirectPage {
    public static func response(status: String, title: String, message: String) -> Data {
        let body = Data("""
            <!doctype html><html><head><meta charset="utf-8"><title>TablePro</title></head>
            <body style="font-family:-apple-system,Helvetica,Arial,sans-serif;text-align:center;padding-top:80px">
            <h2>\(title)</h2><p>\(message)</p></body></html>
            """.utf8)
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Referrer-Policy: no-referrer",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'",
            "Connection: close"
        ]
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }

    public static let badRequest = response(status: "400 Bad Request", title: "Bad Request", message: "")
}

enum LoopbackRedirectLimits {
    static let maximumRequestHeadBytes = 16_384
    static let maximumConnections = 16
    static let maximumKernelPortAttempts = 5
    static let logger = Logger(subsystem: "com.TablePro", category: "LoopbackRedirectListener")

    static func code(of error: NWError) -> Int32 {
        if case .posix(let code) = error { return code.rawValue }
        return -1
    }
}

enum LoopbackPortHold: Sendable {
    case held(Int32)
    case unavailable
    case taken(Int32)

    // Bound but never listening: a browser that tries ::1 first is not answered there and falls back to 127.0.0.1.
    static func ipv6(port: UInt16) -> LoopbackPortHold {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            let failure = errno
            return isUnavailable(failure) ? .unavailable : .taken(failure)
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        guard inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else {
            close(descriptor)
            return .unavailable
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if result == 0 {
            return .held(descriptor)
        }
        let failure = errno
        close(descriptor)
        return isUnavailable(failure) ? .unavailable : .taken(failure)
    }

    private static func isUnavailable(_ code: Int32) -> Bool {
        code == EADDRNOTAVAIL || code == EAFNOSUPPORT || code == EPROTONOSUPPORT
    }
}
