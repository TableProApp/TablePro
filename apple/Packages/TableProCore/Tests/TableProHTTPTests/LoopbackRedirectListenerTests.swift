import Darwin
import Foundation
@testable import TableProHTTP
import Testing

private enum LoopbackProbe {
    static func status(of target: String, port: UInt16) async -> Int? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(target)") else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let request = URLRequest(url: url, timeoutInterval: 5)
        guard let (_, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse
        else {
            return nil
        }
        return httpResponse.statusCode
    }

    static func connectIPv4(port: UInt16) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    // The descriptor bound to [::1]:port, or the errno the bind failed with.
    static func bindIPv6(port: UInt16, listening: Bool = false) -> Result<Int32, POSIXError> {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        _ = inet_pton(AF_INET6, "::1", &address.sin6_addr)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard result == 0 else {
            let failure = errno
            close(descriptor)
            return .failure(POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO))
        }
        if listening {
            _ = listen(descriptor, 4)
        }
        return .success(descriptor)
    }

    static func boundPort(of descriptor: Int32) -> UInt16 {
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(descriptor, generic, &length)
            }
        }
        return UInt16(bigEndian: address.sin6_port)
    }

    // True once the peer closed or reset the connection; false when nothing happened before the timeout.
    static func waitForClose(_ descriptor: Int32, seconds: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var timeout = timeval(tv_sec: seconds, tv_usec: 0)
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var byte: UInt8 = 0
                let received = recv(descriptor, &byte, 1, 0)
                let failure = errno
                continuation.resume(returning: received == 0 || (received < 0 && failure != EAGAIN && failure != EWOULDBLOCK))
            }
        }
    }

    static func listener(port: UInt16 = 0, headTimeout: TimeInterval = 5) -> LoopbackRedirectListener<String> {
        LoopbackRedirectListener(port: port, headTimeout: headTimeout, answer: answer)
    }

    // Settles on a GET to /done and ignores every other request.
    static let answer: LoopbackRedirectListener<String>.Answer = { head in
        let text = LoopbackRedirectRequest.text(of: head)
        guard let target = LoopbackRedirectRequest.getTarget(text), target.hasPrefix("/done") else {
            return .ignore(LoopbackRedirectPage.badRequest)
        }
        return .settle(LoopbackRedirectPage.response(status: "200 OK", title: "Done", message: ""), .success(target))
    }

    static func freeIPv4Port() -> UInt16? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        _ = inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        return bound ? UInt16(bigEndian: address.sin_port) : nil
    }
}

private final class PortAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var tried: [UInt16] = []

    var ports: [UInt16] {
        lock.withLock { tried }
    }

    func record(_ port: UInt16) -> Int {
        lock.withLock {
            tried.append(port)
            return tried.count
        }
    }
}

private struct SampleTimeout: Error, Equatable {}

struct LoopbackRedirectListenerTests {
    @Test("Requests the answer ignores get a reply and leave the wait open for the redirect")
    func strayRequestsAreAnsweredAndIgnored() async throws {
        let listener = LoopbackProbe.listener()
        let port = try await listener.start()
        defer { listener.stop() }
        let outcome = Task { try await listener.outcome(timeout: 30, timeoutError: SampleTimeout()) }

        let stray = await LoopbackProbe.status(of: "/auth?code=forged", port: port)
        let favicon = await LoopbackProbe.status(of: "/favicon.ico", port: port)
        let redirect = await LoopbackProbe.status(of: "/done?code=real", port: port)

        #expect([stray, favicon, redirect] == [400, 400, 200])
        #expect(try await outcome.value == "/done?code=real")
        #expect(await LoopbackProbe.status(of: "/done?again", port: port) == nil)
    }

    @Test("A redirect that lands before anyone waits is kept for the wait")
    func settledBeforeTheWait() async throws {
        let listener = LoopbackProbe.listener()
        let port = try await listener.start()
        defer { listener.stop() }

        #expect(await LoopbackProbe.status(of: "/done", port: port) == 200)
        #expect(try await listener.outcome(timeout: 30, timeoutError: SampleTimeout()) == "/done")
    }

    @Test("A connection that sends no request is closed at the head deadline")
    func idleConnectionIsClosedAtTheDeadline() async throws {
        let listener = LoopbackProbe.listener(headTimeout: 0.2)
        let port = try await listener.start()
        defer { listener.stop() }

        let idle = try #require(LoopbackProbe.connectIPv4(port: port))
        defer { close(idle) }

        #expect(await LoopbackProbe.waitForClose(idle, seconds: 5))
    }

    @Test("Idle sockets filling every slot cannot keep the redirect out")
    func fullTableMakesRoomForTheRedirect() async throws {
        let listener = LoopbackProbe.listener(headTimeout: 60)
        let port = try await listener.start()
        defer { listener.stop() }
        let outcome = Task { try await listener.outcome(timeout: 30, timeoutError: SampleTimeout()) }

        let idle = (0..<20).compactMap { _ in LoopbackProbe.connectIPv4(port: port) }
        defer { idle.forEach { close($0) } }
        #expect(idle.count == 20)

        #expect(await LoopbackProbe.status(of: "/done", port: port) == 200)
        #expect(try await outcome.value == "/done")
    }

    @Test("While it listens, no other socket can take the IPv6 loopback port, and stopping frees it")
    func ipv6LoopbackPortIsHeld() async throws {
        let listener = LoopbackProbe.listener()
        let port = try await listener.start()

        switch LoopbackProbe.bindIPv6(port: port) {
        case .success(let descriptor):
            close(descriptor)
            Issue.record("Another socket took [::1]:\(port) while the listener held it")
        case .failure(let error):
            #expect(error.code == .EADDRINUSE)
        }

        listener.stop()
        switch LoopbackProbe.bindIPv6(port: port) {
        case .success(let descriptor):
            close(descriptor)
        case .failure(let error):
            Issue.record("[::1]:\(port) stayed taken after stop: \(error.code)")
        }
    }

    @Test("A port whose IPv6 loopback side another process holds fails the start")
    func takenIPv6LoopbackPortFailsTheStart() async throws {
        let held = try LoopbackProbe.bindIPv6(port: 0, listening: true).get()
        defer { close(held) }
        let listener = LoopbackProbe.listener(port: LoopbackProbe.boundPort(of: held))

        await #expect(throws: LoopbackRedirectListenerError.portInUse) {
            try await listener.start()
        }
    }

    @Test("A kernel-picked port whose IPv6 loopback side is taken is traded for another")
    func kernelPickedPortTriesAnotherWhenIPv6IsTaken() async throws {
        let attempts = PortAttempts()
        let listener = LoopbackRedirectListener<String>(
            port: 0,
            headTimeout: 5,
            holdIPv6: { port in
                attempts.record(port) < 3 ? .taken(EADDRINUSE) : LoopbackPortHold.ipv6(port: port)
            },
            answer: LoopbackProbe.answer
        )
        let port = try await listener.start()
        defer { listener.stop() }

        #expect(attempts.ports.count == 3)
        #expect(attempts.ports.last == port)
        #expect(await LoopbackProbe.status(of: "/done", port: port) == 200)
    }

    @Test("A kernel-picked port stops trying after a bounded number of taken ports")
    func kernelPickedPortGivesUp() async throws {
        let attempts = PortAttempts()
        let listener = LoopbackRedirectListener<String>(
            port: 0,
            headTimeout: 5,
            holdIPv6: { port in
                _ = attempts.record(port)
                return .taken(EADDRINUSE)
            },
            answer: LoopbackProbe.answer
        )

        await #expect(throws: LoopbackRedirectListenerError.portInUse) {
            try await listener.start()
        }
        #expect(attempts.ports.count == LoopbackRedirectLimits.maximumKernelPortAttempts)
    }

    @Test("A fixed port whose IPv6 loopback side is taken fails without trying another")
    func fixedPortDoesNotTryAnother() async throws {
        let fixed = try #require(LoopbackProbe.freeIPv4Port())
        let attempts = PortAttempts()
        let listener = LoopbackRedirectListener<String>(
            port: fixed,
            headTimeout: 5,
            holdIPv6: { port in
                _ = attempts.record(port)
                return .taken(EADDRINUSE)
            },
            answer: LoopbackProbe.answer
        )

        await #expect(throws: LoopbackRedirectListenerError.portInUse) {
            try await listener.start()
        }
        #expect(attempts.ports == [fixed])
    }

    @Test("Stopping ends the wait")
    func stopEndsTheWait() async throws {
        let listener = LoopbackProbe.listener()
        try await listener.start()
        listener.stop()

        await #expect(throws: CancellationError.self) {
            try await listener.outcome(timeout: 30, timeoutError: SampleTimeout())
        }
    }

    @Test("A wait with no redirect ends with the caller's timeout error")
    func waitTimesOut() async throws {
        let listener = LoopbackProbe.listener()
        try await listener.start()
        defer { listener.stop() }

        await #expect(throws: SampleTimeout()) {
            try await listener.outcome(timeout: 0.2, timeoutError: SampleTimeout())
        }
    }
}
