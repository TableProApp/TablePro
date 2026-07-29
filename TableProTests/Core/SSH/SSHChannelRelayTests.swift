//
//  SSHChannelRelayTests.swift
//  TableProTests
//
//  Tests for SSHChannelRelay termination behaviour. The relay runs over real
//  socketpairs with a scripted channel so the regression case (a closed peer fd
//  must terminate the loop instead of busy-spinning) is exercised end to end.
//

import Foundation
@testable import TablePro
import Testing

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
        timeout: Double = 3
    ) -> RelayTermination? {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        runRelayOnDedicatedThread(
            localFD: localFD,
            transportFD: transportFD,
            io: io,
            isActive: isActive,
            box: box
        ) { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + timeout)
        return box.value
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
    onFinish: @escaping @Sendable () -> Void
) {
    let thread = Thread {
        let relay = SSHChannelRelay(
            localFD: localFD,
            transportFD: transportFD,
            channelIO: io,
            bufferSize: 32_768,
            isActive: isActive
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

private final class FakeChannelIO: SSHChannelIO, @unchecked Sendable {
    enum Action {
        case data(Data)
        case wouldBlock
        case closed
    }

    private let lock = NSLock()
    private var actions: [Action]
    private let fallback: Action
    private var writtenBuffer = Data()

    init(actions: [Action] = [], fallback: Action = .wouldBlock) {
        self.actions = actions
        self.fallback = fallback
    }

    var written: Data {
        lock.lock()
        defer { lock.unlock() }
        return writtenBuffer
    }

    func activeUntilWritten(_ target: Int) -> @Sendable () -> Bool {
        { [weak self] in (self?.written.count ?? target) < target }
    }

    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> ChannelReadResult {
        lock.lock()
        defer { lock.unlock() }
        let action = actions.isEmpty ? fallback : actions.removeFirst()
        switch action {
        case .data(let data):
            let length = min(data.count, count)
            buffer.withMemoryRebound(to: UInt8.self, capacity: length) { destination in
                _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: destination, count: length))
            }
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
