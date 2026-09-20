//
//  SSHChannelRelayTests.swift
//  TableProSSHTransportTests
//
//  Tests for SSHChannelRelay termination behaviour. The relay runs over real
//  socketpairs with a scripted channel so the regression case (a closed peer fd
//  must terminate the loop instead of busy-spinning) is exercised end to end.
//

import Foundation
import Testing

@testable import TableProSSHTransport

@Suite("SSHChannelRelay")
struct SSHChannelRelayTests {
    @Test("Cancellation via isActive stops the relay")
    func cancelled() {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        let result = runRelay(
            localFD: local.a,
            transportFD: transport.a,
            io: FakeChannelIO(fallback: .wouldBlock),
            isActive: { false }
        )

        #expect(result == .cancelled)
    }

    @Test("Transport hangup terminates instead of spinning")
    func transportHangup() {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        transport.closeB()

        let result = runRelay(
            localFD: local.a,
            transportFD: transport.a,
            io: FakeChannelIO(fallback: .wouldBlock)
        )

        #expect(result == .transportHangup)
    }

    @Test("Transport half-close at EOF terminates instead of spinning")
    func transportHalfCloseEOF() {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        shutdown(transport.b, SHUT_WR)

        let result = runRelay(
            localFD: local.a,
            transportFD: transport.a,
            io: FakeChannelIO(fallback: .wouldBlock)
        )

        #expect(result == .transportHangup)
    }

    @Test("Local hangup terminates instead of spinning")
    func localHangup() {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        local.closeB()

        let result = runRelay(
            localFD: local.a,
            transportFD: transport.a,
            io: FakeChannelIO(fallback: .wouldBlock)
        )

        #expect(result == .localClosed)
    }

    @Test("Channel close terminates the relay")
    func channelClosed() {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        let result = runRelay(
            localFD: local.a,
            transportFD: transport.a,
            io: FakeChannelIO(fallback: .closed)
        )

        #expect(result == .channelClosed)
    }

    @Test("Channel data is forwarded to the local socket")
    func forwardsChannelData() {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        let payload = Data("hello".utf8)
        var dummy: UInt8 = 1
        _ = Darwin.send(transport.b, &dummy, 1, 0)

        let io = FakeChannelIO(actions: [.data(payload)], fallback: .closed)
        let result = runRelay(localFD: local.a, transportFD: transport.a, io: io)

        #expect(result == .channelClosed)

        var received = [UInt8](repeating: 0, count: payload.count)
        let count = recv(local.b, &received, received.count, 0)
        #expect(count == payload.count)
        #expect(Data(received) == payload)
    }

    @Test("Local data is forwarded to the channel")
    func forwardsLocalData() {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        let payload = Data("world".utf8)
        payload.withUnsafeBytes { raw in
            _ = Darwin.send(local.b, raw.baseAddress, raw.count, 0)
        }

        let io = FakeChannelIO(fallback: .wouldBlock)
        let result = runRelay(
            localFD: local.a,
            transportFD: transport.a,
            io: io,
            isActive: io.activeUntilWritten(payload.count)
        )

        #expect(result == .cancelled)
        #expect(io.written == payload)
    }

    @Test("Channel data counts as received")
    func countsChannelDataAsReceived() {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        let payload = Data("hello".utf8)
        var dummy: UInt8 = 1
        _ = Darwin.send(transport.b, &dummy, 1, 0)

        let counter = RecordingByteObserver()
        let io = FakeChannelIO(actions: [.data(payload)], fallback: .closed)
        let result = runRelay(localFD: local.a, transportFD: transport.a, io: io, byteCounter: counter)

        #expect(result == .channelClosed)
        #expect(counter.received == payload.count)
        #expect(counter.sent == 0)
    }

    @Test("Local data counts as sent")
    func countsLocalDataAsSent() {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        let payload = Data("world".utf8)
        payload.withUnsafeBytes { raw in
            _ = Darwin.send(local.b, raw.baseAddress, raw.count, 0)
        }

        let counter = RecordingByteObserver()
        let io = FakeChannelIO(fallback: .wouldBlock)
        let result = runRelay(
            localFD: local.a,
            transportFD: transport.a,
            io: io,
            isActive: io.activeUntilWritten(payload.count),
            byteCounter: counter
        )

        #expect(result == .cancelled)
        #expect(counter.received == 0)
        #expect(counter.sent == payload.count)
    }

    @Test("A relay with no counter still runs")
    func runsWithoutACounter() {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        let payload = Data("hello".utf8)
        var dummy: UInt8 = 1
        _ = Darwin.send(transport.b, &dummy, 1, 0)

        let io = FakeChannelIO(actions: [.data(payload)], fallback: .closed)
        let result = runRelay(localFD: local.a, transportFD: transport.a, io: io)

        #expect(result == .channelClosed)
    }

    @Test("Concurrent relays sharing one transport each receive their own channel data")
    func concurrentRelaysShareTransport() {
        let transport = SocketPair()
        let first = SocketPair()
        let second = SocketPair()
        defer { transport.close(); first.close(); second.close() }

        var dummy: UInt8 = 1
        _ = Darwin.send(transport.b, &dummy, 1, 0)

        let firstPayload = Data("first".utf8)
        let secondPayload = Data("second".utf8)
        let firstIO = FakeChannelIO(actions: [.data(firstPayload)], fallback: .closed)
        let secondIO = FakeChannelIO(actions: [.data(secondPayload)], fallback: .closed)

        let group = DispatchGroup()
        let firstBox = ResultBox()
        let secondBox = ResultBox()

        for (localFD, io, box) in [(first.a, firstIO, firstBox), (second.a, secondIO, secondBox)] {
            group.enter()
            runRelayOnDedicatedThread(
                localFD: localFD,
                transportFD: transport.a,
                io: io,
                isActive: { true },
                box: box
            ) { group.leave() }
        }

        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(firstBox.value == .channelClosed)
        #expect(secondBox.value == .channelClosed)
        #expect(readPayload(from: first.b, count: firstPayload.count) == firstPayload)
        #expect(readPayload(from: second.b, count: secondPayload.count) == secondPayload)
    }

    private func readPayload(from fd: Int32, count: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let received = recv(fd, &buffer, count, 0)
        guard received > 0 else { return Data() }
        return Data(buffer.prefix(received))
    }

    private func runRelay(
        localFD: Int32,
        transportFD: Int32,
        io: FakeChannelIO,
        isActive: @escaping @Sendable () -> Bool = { true },
        byteCounter: (any RelayByteObserver)? = nil,
        timeout: Double = 3
    ) -> RelayTermination? {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        runRelayOnDedicatedThread(
            localFD: localFD,
            transportFD: transportFD,
            io: io,
            isActive: isActive,
            box: box,
            byteCounter: byteCounter
        ) { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + timeout)
        return box.value
    }
}

/// The lost wakeup and the drain that follows it, both against a transport fd that is never
/// readable. libssh2 decrypts whole SSH packets into its own buffer, so a second channel on the
/// session holds bytes the transport has already given up: `poll` reports nothing, forever.
///
/// Measured against a real sshd with two channels and 98,304 queued bytes: reading only when the
/// transport polls readable delivered 0 bytes in 60,178ms; pumping on the poll timeout too
/// delivered all of it in 1,504ms with one buffer per timeout; draining until the channel answers
/// EAGAIN delivered all of it in 502ms.
@Suite("SSHChannelRelay backlog drain")
struct SSHChannelRelayBacklogTests {
    fileprivate static let bufferSize = 32_768
    fileprivate static let queuedBuffers = 3

    @Test("A backlog reaches the local socket although the transport never polls readable")
    func deliversBacklogWithoutATransportWakeup() throws {
        let run = try runBacklogRelay()

        #expect(run.delivered == Self.bufferSize * Self.queuedBuffers)
    }

    @Test("One poll round drains the whole backlog instead of one buffer per timeout")
    func drainsInOnePollRound() throws {
        let run = try runBacklogRelay()

        #expect(run.reads == Self.queuedBuffers + 1)
        #expect(run.elapsed < 1.0)
    }

    @Test("A backlog past the per-round cap still lands inside one poll interval")
    func drainsPastTheReadCapWithoutWaiting() throws {
        let run = try runBacklogRelay(buffers: 20)

        #expect(run.delivered == Self.bufferSize * 20)
        #expect(run.reads == 21)
        #expect(run.elapsed < 1.0)
    }

    private struct BacklogRun {
        let delivered: Int
        let reads: Int
        let elapsed: TimeInterval
    }

    /// Drains the local socket on a reader thread so a 96KB backlog cannot fill the socket
    /// buffer and stall the relay inside `send`. The relay stops once the channel has handed
    /// over every queued byte, which is what the two shapes take different numbers of poll
    /// rounds to reach.
    private func runBacklogRelay(buffers: Int = SSHChannelRelayBacklogTests.queuedBuffers) throws -> BacklogRun {
        let local = SocketPair()
        let transport = SocketPair()
        defer { local.close(); transport.close() }

        let total = Self.bufferSize * buffers
        let io = FakeChannelIO(
            actions: Array(repeating: .data(Data(repeating: 0x41, count: Self.bufferSize)), count: buffers),
            fallback: .wouldBlock
        )

        let drained = ByteTally()
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
            while drained.value < total {
                let count = recv(local.b, &buffer, buffer.count, 0)
                if count <= 0 { return }
                drained.add(count)
            }
        }
        reader.stackSize = 512 * 1_024
        reader.start()

        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let started = Date()
        runRelayOnDedicatedThread(
            localFD: local.a,
            transportFD: transport.a,
            io: io,
            isActive: { io.deliveredCount < total },
            box: box
        ) { semaphore.signal() }

        #expect(semaphore.wait(timeout: .now() + 10) == .success)
        let elapsed = Date().timeIntervalSince(started)
        _ = drained.waitUntil(total, timeout: 2)
        return BacklogRun(delivered: drained.value, reads: io.readCount, elapsed: elapsed)
    }
}

/// Runs a relay on a thread of its own rather than borrowing from the shared global
/// queue. The relay loop blocks its thread for as long as it runs, and the test suite
/// runs in parallel, so relays sharing the global queue's bounded pool can starve each
/// other and time out on machines under load.
internal func runRelayOnDedicatedThread(
    localFD: Int32,
    transportFD: Int32,
    io: any SSHChannelIO,
    isActive: @escaping @Sendable () -> Bool,
    box: ResultBox,
    byteCounter: (any RelayByteObserver)? = nil,
    onFinish: @escaping @Sendable () -> Void
) {
    let thread = Thread {
        let relay = SSHChannelRelay(
            localFD: localFD,
            transportFD: transportFD,
            channelIO: io,
            bufferSize: 32_768,
            isActive: isActive,
            byteCounter: byteCounter
        )
        box.value = relay.run()
        onFinish()
    }
    thread.stackSize = 512 * 1_024
    thread.start()
}

internal final class ResultBox: @unchecked Sendable {
    var value: RelayTermination?
}

internal final class ByteTally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func add(_ amount: Int) {
        lock.lock()
        count += amount
        lock.unlock()
    }

    func waitUntil(_ target: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while value < target {
            if Date() >= deadline { return false }
            usleep(2_000)
        }
        return true
    }
}

internal final class RecordingByteObserver: RelayByteObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var receivedBytes = 0
    private var sentBytes = 0

    var received: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedBytes
    }

    var sent: Int {
        lock.lock()
        defer { lock.unlock() }
        return sentBytes
    }

    func recordReceived(_ count: Int) {
        lock.lock()
        receivedBytes += count
        lock.unlock()
    }

    func recordSent(_ count: Int) {
        lock.lock()
        sentBytes += count
        lock.unlock()
    }
}

internal final class FakeChannelIO: SSHChannelIO, @unchecked Sendable {
    enum Action {
        case data(Data)
        case wouldBlock
        case closed
    }

    private let lock = NSLock()
    private var actions: [Action]
    private let fallback: Action
    private var writtenBuffer = Data()
    private var reads = 0
    private var delivered = 0

    init(actions: [Action] = [], fallback: Action = .wouldBlock) {
        self.actions = actions
        self.fallback = fallback
    }

    var written: Data {
        lock.lock()
        defer { lock.unlock() }
        return writtenBuffer
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    var deliveredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    func activeUntilWritten(_ target: Int) -> @Sendable () -> Bool {
        { [weak self] in (self?.written.count ?? target) < target }
    }

    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> ChannelReadResult {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        let action = actions.isEmpty ? fallback : actions.removeFirst()
        switch action {
        case .data(let data):
            let length = min(data.count, count)
            buffer.withMemoryRebound(to: UInt8.self, capacity: length) { destination in
                _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: destination, count: length))
            }
            delivered += length
            return .bytes(length)
        case .wouldBlock:
            return .wouldBlock
        case .closed:
            return .closed
        }
    }

    func write(_ buffer: UnsafePointer<CChar>, count: Int) -> ChannelWriteResult {
        lock.lock()
        defer { lock.unlock() }
        buffer.withMemoryRebound(to: UInt8.self, capacity: count) { source in
            writtenBuffer.append(contentsOf: UnsafeBufferPointer(start: source, count: count))
        }
        return .bytes(count)
    }

    func blockDirections() -> RelayDirections { [] }
}
