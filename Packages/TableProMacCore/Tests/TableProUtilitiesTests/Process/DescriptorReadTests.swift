//
//  DescriptorReadTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

struct DescriptorReadTests {
    @Test("A read returns what has arrived without waiting for the rest", .timeLimit(.minutes(1)))
    func returnsWhatHasArrived() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        try pipe.fileHandleForWriting.write(contentsOf: Data("first".utf8))
        let descriptor = pipe.fileHandleForReading.fileDescriptor

        let bytes = await HeldOpenWriter(pipe.fileHandleForWriting).finishedOnItsOwnThread {
            try? DescriptorRead.availableBytes(from: descriptor)
        } ?? nil

        #expect(bytes == Data("first".utf8))
    }

    @Test("A read takes no more than its limit")
    func stopsAtTheLimit() throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        try pipe.fileHandleForWriting.write(contentsOf: Data("abcdef".utf8))
        try pipe.fileHandleForWriting.close()
        let descriptor = pipe.fileHandleForReading.fileDescriptor

        #expect(try DescriptorRead.availableBytes(from: descriptor, upTo: 4) == Data("abcd".utf8))
        #expect(try DescriptorRead.availableBytes(from: descriptor) == Data("ef".utf8))
    }

    @Test("End of file reads as no bytes")
    func endOfFileIsEmpty() throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        try pipe.fileHandleForWriting.close()

        let bytes = try DescriptorRead.availableBytes(from: pipe.fileHandleForReading.fileDescriptor)

        #expect(bytes.isEmpty)
    }

    @Test(
        "An empty non-blocking pipe is a thrown EAGAIN, the read that raised in a dump's stderr callback",
        .timeLimit(.minutes(1))
    )
    func emptyNonBlockingPipeThrows() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1)

        let outcome = await HeldOpenWriter(pipe.fileHandleForWriting).finishedOnItsOwnThread {
            Result { try DescriptorRead.availableBytes(from: descriptor) }
        }
        let read = try #require(outcome)
        let error = #expect(throws: POSIXError.self) {
            try read.get()
        }

        #expect(error?.code == .EAGAIN)
    }

    @Test("A descriptor that is not open is a thrown EBADF")
    func invalidDescriptorThrows() {
        let error = #expect(throws: POSIXError.self) {
            try DescriptorRead.availableBytes(from: -1)
        }

        #expect(error?.code == .EBADF)
    }

    @Test("Only a pipe holding bytes or at end of file reads without waiting", .timeLimit(.minutes(1)))
    func readinessFollowsThePipe() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        #expect(!DescriptorRead.hasInputWithoutWaiting(descriptor))

        try pipe.fileHandleForWriting.write(contentsOf: Data("x".utf8))
        #expect(DescriptorRead.hasInputWithoutWaiting(descriptor))

        #expect(try DescriptorRead.availableBytes(from: descriptor, upTo: 1) == Data("x".utf8))
        #expect(!DescriptorRead.hasInputWithoutWaiting(descriptor))

        try pipe.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(10)
        while !DescriptorRead.hasInputWithoutWaiting(descriptor), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(DescriptorRead.hasInputWithoutWaiting(descriptor))
    }

    @Test("On a non-blocking pipe the next read waits for bytes instead of failing with EAGAIN", .timeLimit(.minutes(1)))
    func nextBytesWaitsOnANonBlockingPipe() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1)
        BackgroundPipeWriter.write([Data("late".utf8)], to: pipe.fileHandleForWriting, pausingBeforeEach: 0.2)

        let arrived = try #require(await BoundedCall.resultOnItsOwnThread {
            Result { try DescriptorRead.nextBytes(from: descriptor) }
        })
        #expect(try arrived.get() == Data("late".utf8))

        let ended = try #require(await BoundedCall.resultOnItsOwnThread {
            Result { try DescriptorRead.nextBytes(from: descriptor) }
        })
        #expect(try ended.get().isEmpty)
    }

    @Test("Buffered bytes stop at the limit and never wait on a writer that is still open", .timeLimit(.minutes(1)))
    func bufferedBytesTakeWhatThePipeHolds() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let written = Data((0 ..< 10_000).map { UInt8($0 % 251) })
        try pipe.fileHandleForWriting.write(contentsOf: written)
        let writer = HeldOpenWriter(pipe.fileHandleForWriting)

        let first = await writer.finishedOnItsOwnThread {
            DescriptorRead.bufferedBytes(from: descriptor, upTo: 4_096)
        }
        let rest = await writer.finishedOnItsOwnThread {
            DescriptorRead.bufferedBytes(from: descriptor, upTo: DescriptorRead.pipeCapacity)
        }
        let nothing = await writer.finishedOnItsOwnThread {
            DescriptorRead.bufferedBytes(from: descriptor, upTo: DescriptorRead.pipeCapacity)
        }

        #expect(first == written.prefix(4_096))
        #expect(rest == written.dropFirst(4_096))
        #expect(nothing == Data())
        #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK == 0)
    }
}
