//
//  PipeReaderTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

struct PipeReaderTests {
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ chunk: Data) {
            lock.withLock { bytes.append(chunk) }
        }

        var data: Data {
            lock.withLock { bytes }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        func raise() {
            lock.withLock { raised = true }
        }

        var isRaised: Bool {
            lock.withLock { raised }
        }
    }

    private struct TimedOut: Error {}

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Everything written arrives in order and reading ends by itself at end of file", .timeLimit(.minutes(1)))
    func deliversInOrderUntilEndOfFile() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let handle = pipe.fileHandleForReading
        let received = Received()
        let reader = PipeReader(handle)
        reader.start { received.append($0) }

        let payload = Data((0 ..< 3 * DescriptorRead.pipeCapacity).map { UInt8($0 % 251) })
        BackgroundPipeWriter.write([payload], to: pipe.fileHandleForWriting, pausingBeforeEach: 0)

        try await waitUntil { received.data.count == payload.count && handle.readabilityHandler == nil }
        #expect(received.data == payload)
    }

    @Test("A callback dispatched before a drain reads nothing when it runs after it", .timeLimit(.minutes(1)))
    func dispatchedCallbackAfterDrainReadsNothing() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let handle = pipe.fileHandleForReading
        let received = Received()
        let reader = PipeReader(handle)
        reader.start { received.append($0) }
        let dispatched = try #require(handle.readabilityHandler)

        try pipe.fileHandleForWriting.write(contentsOf: Data("early".utf8))
        let writer = HeldOpenWriter(pipe.fileHandleForWriting)
        let drained: Void? = await writer.finishedOnItsOwnThread {
            reader.stop(drainingUpTo: DescriptorRead.pipeCapacity)
        }
        try #require(drained != nil)
        #expect(received.data == Data("early".utf8))

        try pipe.fileHandleForWriting.write(contentsOf: Data("late".utf8))
        let returned: Void? = await writer.finishedOnItsOwnThread { dispatched(handle) }

        try #require(returned != nil)
        #expect(received.data == Data("early".utf8))
        let descriptor = handle.fileDescriptor
        #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK == 0)
        try pipe.fileHandleForWriting.close()
        #expect(try DescriptorRead.availableBytes(from: descriptor) == Data("late".utf8))
    }

    @Test("A callback that finds nothing to read keeps the reader going", .timeLimit(.minutes(1)))
    func callbackWithNothingToReadIsHarmless() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let handle = pipe.fileHandleForReading
        let descriptor = handle.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1)
        let received = Received()
        let reader = PipeReader(handle)
        reader.start { received.append($0) }
        let dispatched = try #require(handle.readabilityHandler)

        let returned: Void? = await BoundedCall.resultOnItsOwnThread { dispatched(handle) }
        try #require(returned != nil)
        #expect(received.data.isEmpty)
        #expect(handle.readabilityHandler != nil)

        try pipe.fileHandleForWriting.write(contentsOf: Data("after".utf8))
        try await waitUntil { received.data == Data("after".utf8) }
        reader.stop()
    }

    @Test(
        "A drain takes what the pipe holds up to its limit and leaves the descriptor blocking",
        .timeLimit(.minutes(1))
    )
    func drainStopsAtTheLimitWithoutWaitingOnTheWriter() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let handle = pipe.fileHandleForReading
        let received = Received()
        let reader = PipeReader(handle)
        reader.start { received.append($0) }
        handle.readabilityHandler = nil

        let buffered = Data((0 ..< 10_000).map { UInt8($0 % 251) })
        try pipe.fileHandleForWriting.write(contentsOf: buffered)
        let drained: Void? = await HeldOpenWriter(pipe.fileHandleForWriting).finishedOnItsOwnThread {
            reader.stop(drainingUpTo: 4_096)
        }

        #expect(drained != nil)
        #expect(received.data == buffered.prefix(4_096))
        let descriptor = handle.fileDescriptor
        #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK == 0)
        try pipe.fileHandleForWriting.close()
        #expect(try DescriptorRead.availableBytes(from: descriptor) == buffered.dropFirst(4_096))
    }

    @Test("Stopping at end of file takes everything written until the last writer closes", .timeLimit(.minutes(1)))
    func stopAtEndOfFileWaitsForTheWriter() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let handle = pipe.fileHandleForReading
        let received = Received()
        let reader = PipeReader(handle)
        reader.start { received.append($0) }
        handle.readabilityHandler = nil

        try pipe.fileHandleForWriting.write(contentsOf: Data("before".utf8))
        BackgroundPipeWriter.write([Data(" after".utf8)], to: pipe.fileHandleForWriting, pausingBeforeEach: 0.2)
        let stopped: Void? = await BoundedCall.resultOnItsOwnThread { reader.stopAtEndOfFile() }

        #expect(stopped != nil)
        #expect(received.data == Data("before after".utf8))
    }

    @Test("Stop waits for a delivery in progress, and nothing is delivered once it returns", .timeLimit(.minutes(1)))
    func stopWaitsForDeliveryInProgress() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let handle = pipe.fileHandleForReading
        let received = Received()
        let entered = Flag()
        let release = DispatchSemaphore(value: 0)
        let reader = PipeReader(handle)
        reader.start { chunk in
            entered.raise()
            release.wait()
            received.append(chunk)
        }

        try pipe.fileHandleForWriting.write(contentsOf: Data("first".utf8))
        try await waitUntil { entered.isRaised }

        let stopped = Flag()
        Thread.detachNewThread {
            reader.stop(drainingUpTo: DescriptorRead.pipeCapacity)
            stopped.raise()
        }
        try await waitUntil { handle.readabilityHandler == nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!stopped.isRaised)

        release.signal()
        try await waitUntil { stopped.isRaised }
        #expect(received.data == Data("first".utf8))

        try pipe.fileHandleForWriting.write(contentsOf: Data("second".utf8))
        try await Task.sleep(for: .milliseconds(50))
        #expect(received.data == Data("first".utf8))
    }
}
