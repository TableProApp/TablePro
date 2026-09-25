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
        let writer = pipe.fileHandleForWriting
        Thread.detachNewThread {
            try? writer.write(contentsOf: payload)
            try? writer.close()
        }

        try await waitUntil { received.data.count == payload.count && handle.readabilityHandler == nil }
        #expect(received.data == payload)
    }

    /// The order that crashed a dump: the process exits, the termination handler drains the pipe
    /// while a readability callback Foundation had already dispatched waits, and the callback then
    /// reads a pipe that is empty with its writer still open.
    @Test("A callback dispatched before a drain reads nothing when it runs after it", .timeLimit(.minutes(1)))
    func dispatchedCallbackAfterDrainReadsNothing() throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let handle = pipe.fileHandleForReading
        let received = Received()
        let reader = PipeReader(handle)
        reader.start { received.append($0) }
        let dispatched = try #require(handle.readabilityHandler)

        try pipe.fileHandleForWriting.write(contentsOf: Data("early".utf8))
        reader.stop(drainingUpTo: DescriptorRead.pipeCapacity)
        #expect(received.data == Data("early".utf8))

        dispatched(handle)
        try pipe.fileHandleForWriting.write(contentsOf: Data("late".utf8))
        dispatched(handle)

        #expect(received.data == Data("early".utf8))
        let descriptor = handle.fileDescriptor
        #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK == 0)
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

        dispatched(handle)
        #expect(received.data.isEmpty)
        #expect(handle.readabilityHandler != nil)

        try pipe.fileHandleForWriting.write(contentsOf: Data("after".utf8))
        try await waitUntil { received.data == Data("after".utf8) }
        reader.stop()
    }

    @Test("A drain takes what the pipe holds up to its limit and leaves the descriptor blocking")
    func drainStopsAtTheLimitWithoutWaitingOnTheWriter() throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let handle = pipe.fileHandleForReading
        let received = Received()
        let reader = PipeReader(handle)
        reader.start { received.append($0) }
        handle.readabilityHandler = nil

        let buffered = Data((0 ..< 10_000).map { UInt8($0 % 251) })
        try pipe.fileHandleForWriting.write(contentsOf: buffered)
        reader.stop(drainingUpTo: 4_096)

        #expect(received.data == buffered.prefix(4_096))
        let descriptor = handle.fileDescriptor
        #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK == 0)
        #expect(try DescriptorRead.availableBytes(from: descriptor) == buffered.dropFirst(4_096))
    }

    @Test("Stopping at end of file takes everything written until the last writer closes", .timeLimit(.minutes(1)))
    func stopAtEndOfFileWaitsForTheWriter() throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let handle = pipe.fileHandleForReading
        let received = Received()
        let reader = PipeReader(handle)
        reader.start { received.append($0) }
        handle.readabilityHandler = nil

        let writer = pipe.fileHandleForWriting
        try writer.write(contentsOf: Data("before".utf8))
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.2)
            try? writer.write(contentsOf: Data(" after".utf8))
            try? writer.close()
        }
        reader.stopAtEndOfFile()

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
