//
//  SSHSessionPumpTests.swift
//  TableProSSHTransportTests
//
//  The pump runs over real socketpairs with scripted channels, so a closed peer, a full socket and
//  a quiet transport behave the way a database client and an SSH server would make them behave.
//

import Foundation
import os
import TableProTestSupport
import Testing

@testable import TableProSSHTransport

struct SSHSessionPumpTests {
    @Test("Stopping the pump ends its relays as cancelled and closes their sockets")
    func stopCancels() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        let ended = fixture.relay(local, io: FakeChannelIO(fallback: .wouldBlock))
        fixture.pump.stop()

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .cancelled)
        #expect(readsEndOfFile(local.b))
    }

    @Test("A relay added after stop ends as cancelled and its socket is closed")
    func relayAfterStopCancels() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        fixture.pump.stop()
        let ended = fixture.relay(local, io: FakeChannelIO(fallback: .wouldBlock))

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .cancelled)
        #expect(readsEndOfFile(local.b))
    }

    @Test("Once stopped, every relay has ended and closed its socket")
    func waitUntilStoppedCoversRelays() async throws {
        let fixture = PumpFixture()
        let first = SocketPair()
        let second = SocketPair()
        defer { first.close(); second.close(); fixture.close() }

        let firstEnded = fixture.relay(first, io: FakeChannelIO(fallback: .wouldBlock))
        let secondEnded = fixture.relay(second, io: FakeChannelIO(fallback: .wouldBlock))
        fixture.pump.stop()
        await fixture.pump.waitUntilStopped()

        #expect(firstEnded.value == .cancelled)
        #expect(secondEnded.value == .cancelled)
        #expect(readsEndOfFile(first.b))
        #expect(readsEndOfFile(second.b))
    }

    @Test("Transport hangup ends the relay instead of spinning")
    func transportHangup() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        fixture.transport.closeB()
        let ended = fixture.relay(local, io: FakeChannelIO(fallback: .wouldBlock))

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .transportHangup)
    }

    @Test("Transport half-close at EOF ends the relay instead of spinning")
    func transportHalfCloseEOF() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        shutdown(fixture.transport.b, SHUT_WR)
        let ended = fixture.relay(local, io: FakeChannelIO(fallback: .wouldBlock))

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .transportHangup)
    }

    @Test("Local hangup ends the relay instead of spinning")
    func localHangup() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        local.closeB()
        let ended = fixture.relay(local, io: FakeChannelIO(fallback: .wouldBlock))

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .localClosed)
    }

    @Test("Channel close ends the relay")
    func channelClosed() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        let ended = fixture.relay(local, io: FakeChannelIO(fallback: .closed))

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .channelClosed)
    }

    @Test("A transport failure on read ends as a transport hangup, not a channel close")
    func readTransportFailureIsHangup() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        let ended = fixture.relay(local, io: FakeChannelIO(fallback: .transportFailed))

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .transportHangup)
    }

    @Test("A transport failure on read after the SSH server hung up ends as a transport hangup")
    func readTransportFailureAfterHangupIsHangup() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        fixture.transport.closeB()
        let ended = fixture.relay(local, io: FakeChannelIO(fallback: .transportFailed))

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .transportHangup)
    }

    @Test("A transport failure on write ends as a transport hangup, not a channel close")
    func writeTransportFailureIsHangup() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        send(Data("world".utf8), to: local.b)
        let ended = fixture.relay(local, io: FakeChannelIO(fallback: .wouldBlock, writeFallback: .transportFailed))

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .transportHangup)
    }

    @Test("Channel data for a client that already closed ends the relay as a local close")
    func channelDataForClosedClientIsLocalClose() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        local.closeB()
        let payload = Data("rows".utf8)
        let io = FakeChannelIO(actions: [.data(payload)], fallback: .wouldBlock)
        let ended = fixture.relay(local, io: io)

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .localClosed)
        #expect(io.readCount == 1)
        #expect(io.deliveredCount == payload.count)
    }

    @Test("Channel data is forwarded to the local socket")
    func forwardsChannelData() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        let payload = Data("hello".utf8)
        let ended = fixture.relay(local, io: FakeChannelIO(actions: [.data(payload)], fallback: .closed))

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .channelClosed)
        #expect(receive(from: local.b, count: payload.count) == payload)
    }

    @Test("Local data is forwarded to the channel")
    func forwardsLocalData() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        let payload = Data("world".utf8)
        send(payload, to: local.b)
        let io = FakeChannelIO(fallback: .wouldBlock)
        _ = fixture.relay(local, io: io)

        try await waitUntil { io.written.count >= payload.count }
        #expect(io.written == payload)
    }

    @Test("Channel data counts as received and local data as sent")
    func countsBothDirections() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        let incoming = Data("hello".utf8)
        let outgoing = Data("world!".utf8)
        send(outgoing, to: local.b)
        let counter = RecordingByteObserver()
        let io = FakeChannelIO(actions: [.data(incoming)], fallback: .wouldBlock)
        _ = fixture.relay(local, io: io, counter: counter)

        try await waitUntil { counter.received == incoming.count && counter.sent == outgoing.count }
        #expect(io.written == outgoing)
    }

    @Test("Relays sharing one session each receive their own channel data")
    func relaysShareOneSession() async throws {
        let fixture = PumpFixture()
        let first = SocketPair()
        let second = SocketPair()
        defer { first.close(); second.close(); fixture.close() }

        let firstPayload = Data("first".utf8)
        let secondPayload = Data("second".utf8)
        let firstEnded = fixture.relay(first, io: FakeChannelIO(actions: [.data(firstPayload)], fallback: .closed))
        let secondEnded = fixture.relay(second, io: FakeChannelIO(actions: [.data(secondPayload)], fallback: .closed))

        try await waitUntil { firstEnded.value != nil && secondEnded.value != nil }
        #expect(firstEnded.value == .channelClosed)
        #expect(secondEnded.value == .channelClosed)
        #expect(receive(from: first.b, count: firstPayload.count) == firstPayload)
        #expect(receive(from: second.b, count: secondPayload.count) == secondPayload)
    }

    // The lost wakeup: libssh2 drains every packet on the transport into its own queue whenever any
    // channel reads, so data for a channel served earlier in a pass sits there with the socket quiet.
    @Test("Data another channel's read queued reaches its client without a transport event")
    func deliversDataAnotherReadQueued() async throws {
        let fixture = PumpFixture()
        let early = SocketPair()
        let late = SocketPair()
        defer { early.close(); late.close(); fixture.close() }

        let earlyIO = FakeChannelIO(fallback: .wouldBlock)
        let queuedForEarly = Data("queued".utf8)
        let lateIO = FakeChannelIO(actions: [.data(Data("late".utf8))], fallback: .wouldBlock) { reads in
            if reads == 1 { earlyIO.enqueue(.data(queuedForEarly)) }
        }
        _ = fixture.relay(early, io: earlyIO)
        try await waitUntil { earlyIO.readCount >= 1 }
        _ = fixture.relay(late, io: lateIO)

        try await waitUntil(timeout: .seconds(2)) { earlyIO.deliveredCount == queuedForEarly.count }
        #expect(receive(from: early.b, count: queuedForEarly.count) == queuedForEarly)
    }

    @Test("An idle relay makes no channel call")
    func idleRelayMakesNoCall() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        let io = FakeChannelIO(fallback: .wouldBlock)
        _ = fixture.relay(local, io: io)
        try await waitUntil { io.readCount >= 1 }
        let settled = io.readCount

        // The previous relay read the channel on a 500 ms timer, so this window would have caught one.
        try await Task.sleep(for: .milliseconds(700))
        #expect(io.readCount == settled)
        #expect(io.writeCount == 0)
    }

    @Test("A call on the session relays whatever it queued")
    func performRelaysWhatItQueued() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        let io = FakeChannelIO(fallback: .wouldBlock)
        _ = fixture.relay(local, io: io)
        try await waitUntil { io.readCount >= 1 }

        let payload = Data("drained by an open".utf8)
        fixture.pump.perform { io.enqueue(.data(payload)) }

        #expect(io.deliveredCount == payload.count)
        #expect(receive(from: local.b, count: payload.count) == payload)
    }

    // The SQLite agent's heartbeats travel client to channel while its rows wait for a slow reader.
    @Test("Local data keeps reaching the channel while the client is not reading")
    func localDataFlowsWhileClientDoesNotRead() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        let chunk = Data(repeating: 0x52, count: 32_768)
        let io = FakeChannelIO(actions: Array(repeating: .data(chunk), count: 64), fallback: .wouldBlock)
        _ = fixture.relay(local, io: io)
        try await waitUntil { io.readCount >= 1 }

        let heartbeat = Data("heartbeat".utf8)
        send(heartbeat, to: local.b)

        try await waitUntil(timeout: .seconds(2)) { io.written == heartbeat }
        #expect(io.deliveredCount < chunk.count * 64)
    }

    @Test("A write waiting on the transport resumes once the transport can take data")
    func writeResumesWhenTransportWritable() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        fillSendBuffer(fixture.transport.a)
        let payload = Data("query".utf8)
        send(payload, to: local.b)
        let io = FakeChannelIO(fallback: .wouldBlock, writeResults: [.wouldBlock], writeBlocks: .outbound)
        _ = fixture.relay(local, io: io)
        try await waitUntil { io.writeCount >= 1 }
        #expect(io.written.isEmpty)

        drain(fixture.transport.b)

        try await waitUntil(timeout: .seconds(2)) { io.written == payload }
    }

    // Freeing a channel with a packet half sent would leave libssh2 refusing every later send.
    @Test("A relay whose write is in flight ends only once that write finishes")
    func inFlightWriteFinishesBeforeEnd() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        send(Data("x".utf8), to: local.b)
        let io = FakeChannelIO(
            actions: [.wouldBlock],
            fallback: .closed,
            writeResults: [.wouldBlock, .wouldBlock, .bytes(1)],
            writeBlocks: .outbound
        )
        let ended = fixture.relay(local, io: io)
        try await waitUntil { io.writeCount >= 1 }
        send(Data([1]), to: fixture.transport.b)

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .channelClosed)
        #expect(io.writeCount == 3)
    }

    // A read can owe its window adjust, which only another read on that channel sends.
    @Test("A relay whose read waits to send ends only once that read goes through")
    func readOwingASendFinishesBeforeEnd() async throws {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        local.closeB()
        let io = FakeChannelIO(actions: [.wouldBlock, .wouldBlock], fallback: .closed, readBlocks: .outbound)
        let ended = fixture.relay(local, io: io)

        try await waitUntil { ended.value != nil }
        #expect(ended.value == .localClosed)
        #expect(io.readCount == 3)
    }

    // libssh2 takes a window adjust off the transport whichever channel reads, and the writer waits on no socket.
    @Test("A write waiting on the window goes out once another channel's read opens it")
    func writeGoesOutWhenAnotherReadOpensItsWindow() async throws {
        let fixture = PumpFixture()
        let writer = SocketPair()
        let reader = SocketPair()
        defer { writer.close(); reader.close(); fixture.close() }

        let payload = Data("query".utf8)
        send(payload, to: writer.b)
        let writerIO = FakeChannelIO(fallback: .wouldBlock, sendWindow: false)
        _ = fixture.relay(writer, io: writerIO)
        try await waitUntil { writerIO.writeCount >= 1 }
        #expect(writerIO.written.isEmpty)

        let readerIO = FakeChannelIO(actions: [.data(Data("rows".utf8))], fallback: .wouldBlock) { reads in
            if reads == 1 { writerIO.openWindow() }
        }
        _ = fixture.relay(reader, io: readerIO)

        try await waitUntil(timeout: .seconds(2)) { writerIO.written == payload }
    }

    // libssh2 sends one packet at a time per session, so an upload that always has one on its way would refuse
    // every other channel's write until it ends.
    @Test("A message gets through beside an upload limited by the socket")
    func messageGetsThroughBesideUpload() async throws {
        let fixture = PumpFixture()
        let uploader = SocketPair()
        let messenger = SocketPair()
        defer { uploader.close(); messenger.close(); fixture.close() }

        let session = OnePacketSession(transportFD: fixture.transport.a)
        let drain = SlowDrain(fixture.transport.b)
        defer { drain.stop() }
        let uploaderIO = session.channel()
        let messengerIO = session.channel()
        let upload = Data(repeating: 0x55, count: 16 << 20)
        enlargeBuffers(uploader)
        let peer = uploader.b
        Thread { _ = upload.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, MSG_NOSIGNAL) } }.start()
        _ = fixture.relay(uploader, io: uploaderIO)
        try await waitUntil { uploaderIO.writtenCount > 0 }

        let message = Data("hello".utf8)
        send(message, to: messenger.b)
        _ = fixture.relay(messenger, io: messengerIO)

        try await waitUntil(timeout: .seconds(2)) { messengerIO.writtenCount == message.count }
        #expect(uploaderIO.writtenCount < upload.count)
    }

    @Test("An outside call waiting to send gets a gap beside an upload limited by the socket")
    func outsideCallGetsAGapBesideUpload() async throws {
        let fixture = PumpFixture()
        let uploader = SocketPair()
        defer { uploader.close(); fixture.close() }

        let session = OnePacketSession(transportFD: fixture.transport.a)
        let drain = SlowDrain(fixture.transport.b)
        defer { drain.stop() }
        let uploaderIO = session.channel()
        let upload = Data(repeating: 0x55, count: 16 << 20)
        enlargeBuffers(uploader)
        let peer = uploader.b
        Thread { _ = upload.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, MSG_NOSIGNAL) } }.start()
        _ = fixture.relay(uploader, io: uploaderIO)
        try await waitUntil { session.isSending }

        let turn = SSHSendTurn(pump: fixture.pump)
        turn.waitsToSend(true)
        defer { turn.end() }
        let pump = fixture.pump
        try await waitUntil(timeout: .seconds(2)) { pump.perform { !session.isSending } }
        #expect(uploaderIO.writtenCount < upload.count)
    }

    // A write that finds no window clears libssh2's outbound bit while another channel's packet is on its way.
    @Test("An upload keeps going beside a channel whose window is closed")
    func uploadKeepsGoingBesideAClosedWindow() async throws {
        let fixture = PumpFixture()
        let uploader = SocketPair()
        let waiter = SocketPair()
        defer { uploader.close(); waiter.close(); fixture.close() }

        let session = OnePacketSession(transportFD: fixture.transport.a)
        let drain = SlowDrain(fixture.transport.b)
        defer { drain.stop() }
        let uploaderIO = session.channel()
        let waiterIO = session.channel(windowClosed: true)
        let upload = Data(repeating: 0x55, count: 16 << 20)
        enlargeBuffers(uploader)
        let peer = uploader.b
        Thread { _ = upload.withUnsafeBytes { Darwin.send(peer, $0.baseAddress, $0.count, MSG_NOSIGNAL) } }.start()
        _ = fixture.relay(uploader, io: uploaderIO)
        try await waitUntil { session.isSending }

        send(Data("waits".utf8), to: waiter.b)
        _ = fixture.relay(waiter, io: waiterIO)
        try await waitUntil { waiterIO.writeCount >= 2 }
        let drainedBefore = drain.drained

        // Progress through the transport, at whatever pace the drain thread gets on a loaded machine: a stalled
        // pump lets through only what already sat in the socket.
        try await waitUntil(timeout: .seconds(15)) { drain.drained >= drainedBefore + (256 << 10) }
        #expect(uploaderIO.writtenCount < upload.count)
    }
}

// libssh2 decrypts whole SSH packets into its own buffer, so a channel can hold more than one
// buffer's worth while the transport reports nothing new.
//
// Measured against a real sshd with two channels and 98,304 queued bytes: reading only when the
// transport polls readable delivered 0 bytes in 60,178ms; pumping on a 500ms poll timeout too
// delivered all of it in 1,504ms with one buffer per timeout; draining until the channel answers
// EAGAIN delivered all of it in 502ms.
struct SSHSessionPumpBacklogTests {
    fileprivate static let bufferSize = 32_768
    fileprivate static let queuedBuffers = 3

    @Test("A backlog reaches the local socket although the transport never turns readable")
    func deliversBacklogWithoutATransportWakeup() async throws {
        let run = try await runBacklog()

        #expect(run.delivered == Self.bufferSize * Self.queuedBuffers)
    }

    @Test("One pass drains the whole backlog instead of one buffer per wakeup")
    func drainsInOnePass() async throws {
        let run = try await runBacklog()

        #expect(run.reads == Self.queuedBuffers + 1)
    }

    @Test("A backlog past the per-pass cap still lands at once")
    func drainsPastTheReadCapWithoutWaiting() async throws {
        let run = try await runBacklog(buffers: 20)

        #expect(run.delivered == Self.bufferSize * 20)
        // The pass the cap scheduled can run after a local event's pass took the last buffer, and read once more.
        #expect((21 ... 22).contains(run.reads))
        #expect(run.elapsed < 1.0)
    }

    private struct BacklogRun {
        let delivered: Int
        let reads: Int
        let elapsed: TimeInterval
    }

    // Drains the local socket on a reader thread so a backlog bigger than the socket buffer
    // cannot stall the relay on a full socket.
    private func runBacklog(buffers: Int = SSHSessionPumpBacklogTests.queuedBuffers) async throws -> BacklogRun {
        let fixture = PumpFixture()
        let local = SocketPair()
        defer { local.close(); fixture.close() }

        let total = Self.bufferSize * buffers
        let io = FakeChannelIO(
            actions: Array(repeating: .data(Data(repeating: 0x41, count: Self.bufferSize)), count: buffers),
            fallback: .wouldBlock
        )

        let drained = ByteTally()
        let peer = local.b
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
            while drained.value < total {
                let count = recv(peer, &buffer, buffer.count, 0)
                if count <= 0 { return }
                drained.add(count)
            }
        }
        reader.stackSize = 512 * 1_024
        reader.start()

        let started = Date()
        _ = fixture.relay(local, io: io)
        try await waitUntil { drained.value >= total && io.readCount > buffers }
        let elapsed = Date().timeIntervalSince(started)
        return BacklogRun(delivered: drained.value, reads: io.readCount, elapsed: elapsed)
    }
}

// MARK: - Support

internal final class PumpFixture: @unchecked Sendable {
    let transport = SocketPair()
    let pump: SSHSessionPump

    init() {
        pump = SSHSessionPump(transportFD: transport.a, queue: DispatchQueue(label: "com.TablePro.tests.ssh.pump"))
    }

    func relay(_ local: SocketPair, io: any SSHChannelIO, counter: (any RelayByteObserver)? = nil) -> EndRecorder {
        let ended = EndRecorder()
        pump.relay(localFD: local.takeA(), channel: io, bufferSize: 32_768, byteCounter: counter) { termination in
            ended.record(termination)
        }
        return ended
    }

    // The transport closes only after no source of the pump can fire on it, without holding a test thread.
    func close() {
        pump.stop()
        pump.whenStopped { [self] in transport.close() }
    }
}

internal final class EndRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var termination: RelayTermination?

    var value: RelayTermination? {
        lock.withLock { termination }
    }

    func record(_ termination: RelayTermination) {
        lock.withLock {
            if self.termination == nil { self.termination = termination }
        }
    }
}

internal final class ByteTally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func add(_ amount: Int) {
        lock.withLock { count += amount }
    }
}

internal final class RecordingByteObserver: RelayByteObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var receivedBytes = 0
    private var sentBytes = 0

    var received: Int {
        lock.withLock { receivedBytes }
    }

    var sent: Int {
        lock.withLock { sentBytes }
    }

    func recordReceived(_ count: Int) {
        lock.withLock { receivedBytes += count }
    }

    func recordSent(_ count: Int) {
        lock.withLock { sentBytes += count }
    }
}

internal final class FakeChannelIO: SSHChannelIO, @unchecked Sendable {
    enum Action {
        case data(Data)
        case wouldBlock
        case closed
        case transportFailed
    }

    private let lock = NSLock()
    private var actions: [Action]
    private let fallback: Action
    private var writeResults: [ChannelWriteResult]
    private let writeFallback: ChannelWriteResult?
    private let readBlocks: RelayDirections
    private let writeBlocks: RelayDirections
    private var sendWindow: Bool
    private let onRead: (@Sendable (Int) -> Void)?
    private var lastBlock: RelayDirections = []
    private var writtenBuffer = Data()
    private var reads = 0
    private var writes = 0
    private var delivered = 0

    // The directions answer for the last call that would block, as libssh2's do.
    init(
        actions: [Action] = [],
        fallback: Action = .wouldBlock,
        writeResults: [ChannelWriteResult] = [],
        writeFallback: ChannelWriteResult? = nil,
        readBlocks: RelayDirections = [],
        writeBlocks: RelayDirections = [],
        sendWindow: Bool = true,
        onRead: (@Sendable (Int) -> Void)? = nil
    ) {
        self.actions = actions
        self.fallback = fallback
        self.writeResults = writeResults
        self.writeFallback = writeFallback
        self.readBlocks = readBlocks
        self.writeBlocks = writeBlocks
        self.sendWindow = sendWindow
        self.onRead = onRead
    }

    var written: Data { lock.withLock { writtenBuffer } }
    var readCount: Int { lock.withLock { reads } }
    var writeCount: Int { lock.withLock { writes } }
    var deliveredCount: Int { lock.withLock { delivered } }

    func enqueue(_ action: Action) {
        lock.withLock { actions.append(action) }
    }

    func openWindow() {
        lock.withLock { sendWindow = true }
    }

    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> ChannelReadResult {
        let (action, readNumber) = lock.withLock { () -> (Action, Int) in
            reads += 1
            let action = actions.isEmpty ? fallback : actions.removeFirst()
            if case .wouldBlock = action { lastBlock = readBlocks } else { lastBlock = [] }
            return (action, reads)
        }
        onRead?(readNumber)
        switch action {
        case .data(let data):
            let length = min(data.count, count)
            buffer.withMemoryRebound(to: UInt8.self, capacity: length) { destination in
                _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: destination, count: length))
            }
            lock.withLock { delivered += length }
            return .bytes(length)
        case .wouldBlock:
            return .wouldBlock
        case .closed:
            return .closed
        case .transportFailed:
            return .transportFailed
        }
    }

    func write(_ buffer: UnsafePointer<CChar>, count: Int) -> ChannelWriteResult {
        lock.withLock {
            writes += 1
            guard sendWindow else {
                lastBlock = .inbound
                return .wouldBlock
            }
            let result = writeResults.isEmpty ? (writeFallback ?? .bytes(count)) : writeResults.removeFirst()
            lastBlock = result == .wouldBlock ? writeBlocks : []
            guard case .bytes(let accepted) = result else { return result }
            let length = min(accepted, count)
            buffer.withMemoryRebound(to: UInt8.self, capacity: length) { source in
                writtenBuffer.append(contentsOf: UnsafeBufferPointer(start: source, count: length))
            }
            return .bytes(length)
        }
    }

    func blockDirections() -> RelayDirections {
        lock.withLock { lastBlock }
    }

    func hasQueuedInput() -> Bool {
        lock.withLock { !actions.isEmpty }
    }

    func hasSendWindow() -> Bool {
        lock.withLock { sendWindow }
    }
}

private func send(_ data: Data, to descriptor: Int32) {
    data.withUnsafeBytes { raw in
        _ = Darwin.send(descriptor, raw.baseAddress, raw.count, 0)
    }
}

private func receive(from descriptor: Int32, count: Int) -> Data {
    var buffer = [UInt8](repeating: 0, count: count)
    var received = 0
    while received < count {
        let got = buffer.withUnsafeMutableBytes { raw in
            recv(descriptor, raw.baseAddress?.advanced(by: received), count - received, 0)
        }
        if got <= 0 { break }
        received += got
    }
    return Data(buffer.prefix(received))
}

private func readsEndOfFile(_ descriptor: Int32) -> Bool {
    var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&pollFD, 1, 2_000) > 0 else { return false }
    var byte: UInt8 = 0
    return recv(descriptor, &byte, 1, 0) == 0
}

// The client side feeds the relay whole 32 KB reads, so the 8 KB transport is what the upload waits on.
private func enlargeBuffers(_ pair: SocketPair) {
    var size: Int32 = 1 << 20
    for descriptor in [pair.a, pair.b] {
        setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }
}

private func fillSendBuffer(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFL, 0)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    var chunk = [UInt8](repeating: 0x46, count: 4_096)
    while Darwin.send(descriptor, &chunk, chunk.count, 0) > 0 {}
}

private func drain(_ descriptor: Int32) {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT) > 0 {}
}

// A session that, like libssh2, keeps one packet at a time on its way and refuses every other channel's write
// until the channel that started it sends the rest. Packets go into the real transport socket, so its writability
// is what a write source sees. The outbound bit follows libssh2's: set when a send would block, left alone by a
// partial retry, cleared once the packet is out, and cleared outright by a write that finds no window.
internal final class OnePacketSession: @unchecked Sendable {
    private let lock = NSLock()
    private let transportFD: Int32
    private var owner: ObjectIdentifier?
    private var outbound = false
    private var remaining = 0
    private var payload = 0
    private let filler = [UInt8](repeating: 0x50, count: 32_768)

    // Non-blocking as libssh2 leaves its socket: Darwin does not honor MSG_DONTWAIT on a send to a Unix socket.
    init(transportFD: Int32) {
        self.transportFD = transportFD
        let flags = fcntl(transportFD, F_GETFL, 0)
        _ = fcntl(transportFD, F_SETFL, flags | O_NONBLOCK)
    }

    var isSending: Bool {
        lock.withLock { owner != nil }
    }

    var outboundBit: Bool {
        lock.withLock { outbound }
    }

    func channel(windowClosed: Bool = false) -> OnePacketChannel {
        OnePacketChannel(session: self, windowClosed: windowClosed)
    }

    func writeWithNoWindow() -> ChannelWriteResult {
        lock.withLock {
            outbound = false
            return .wouldBlock
        }
    }

    func write(from channel: OnePacketChannel, count: Int) -> ChannelWriteResult {
        lock.withLock {
            let id = ObjectIdentifier(channel)
            if let owner {
                guard owner == id else { return .wouldBlock }
                let sent = push(remaining)
                if sent == 0 { outbound = true }
                remaining -= sent
                guard remaining == 0 else { return .wouldBlock }
                self.owner = nil
                outbound = false
                return .bytes(payload)
            }
            let packet = min(count, filler.count)
            let sent = push(packet)
            guard sent == packet else {
                owner = id
                outbound = true
                remaining = packet - sent
                payload = packet
                return .wouldBlock
            }
            outbound = false
            return .bytes(packet)
        }
    }

    private func push(_ count: Int) -> Int {
        let sent = filler.withUnsafeBytes { Darwin.send(transportFD, $0.baseAddress, count, 0) }
        return max(0, sent)
    }
}

internal final class OnePacketChannel: SSHChannelIO, @unchecked Sendable {
    private let session: OnePacketSession
    private let windowClosed: Bool
    private let lock = NSLock()
    private var written = 0
    private var writes = 0

    init(session: OnePacketSession, windowClosed: Bool) {
        self.session = session
        self.windowClosed = windowClosed
    }

    var writtenCount: Int { lock.withLock { written } }
    var writeCount: Int { lock.withLock { writes } }

    func read(into buffer: UnsafeMutablePointer<CChar>, count: Int) -> ChannelReadResult { .wouldBlock }

    func write(_ buffer: UnsafePointer<CChar>, count: Int) -> ChannelWriteResult {
        lock.withLock { writes += 1 }
        if windowClosed { return session.writeWithNoWindow() }
        let result = session.write(from: self, count: count)
        if case .bytes(let accepted) = result {
            lock.withLock { written += accepted }
        }
        return result
    }

    func blockDirections() -> RelayDirections { session.outboundBit ? .outbound : [] }

    func hasQueuedInput() -> Bool { false }

    func hasSendWindow() -> Bool { !windowClosed }
}

// Reads the far end of the transport at about 4 MB/s, so an upload fills the socket and waits on it. It reads a
// descriptor of its own, so it never reads a number the test has closed and the kernel handed to another test.
internal final class SlowDrain: @unchecked Sendable {
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let tally = ByteTally()

    var drained: Int { tally.value }

    init(_ descriptor: Int32) {
        let stopped = self.stopped
        let tally = self.tally
        let own = dup(descriptor)
        let thread = Thread {
            defer { Darwin.close(own) }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while !stopped.withLock({ $0 }) {
                let count = recv(own, &buffer, buffer.count, MSG_DONTWAIT)
                if count <= 0 {
                    usleep(1_000)
                    continue
                }
                tally.add(count)
                usleep(4_000)
            }
        }
        thread.start()
    }

    func stop() {
        stopped.withLock { $0 = true }
    }
}
