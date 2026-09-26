//
//  DescriptorWriteTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

struct DescriptorWriteTests {
    private struct Measured: Sendable {
        let outcome: Result<Void, any Error>
        let processorTime: Duration
    }

    private static func threadProcessorTime() -> Duration {
        .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }

    @Test("A write to a full non-blocking pipe waits for room instead of spinning", .timeLimit(.minutes(1)))
    func writeWaitsForRoomWithoutSpinning() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let writer = pipe.fileHandleForWriting
        let descriptor = writer.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1)
        #expect(fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1)
        let payload = Data((0 ..< 4 * DescriptorRead.pipeCapacity).map { UInt8($0 % 251) })

        async let drained = BackgroundPipeReader.everything(from: pipe.fileHandleForReading, pausingFirst: 1)
        let measured = await BoundedCall.resultOnItsOwnThread {
            let started = Self.threadProcessorTime()
            let outcome = Result { try DescriptorWrite.allBytes(payload, to: descriptor) }
            let processorTime = Self.threadProcessorTime() - started
            try? writer.close()
            return Measured(outcome: outcome, processorTime: processorTime)
        }

        let written = try #require(measured)
        let received = try #require(await drained)
        #expect(throws: Never.self) { try written.outcome.get() }
        #expect(received == payload)
        #expect(written.processorTime < .milliseconds(50))
    }

    @Test("A write to a pipe nobody reads is a thrown EPIPE, not a wait", .timeLimit(.minutes(1)))
    func writeWithNoReaderThrows() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1)
        #expect(fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1)
        try pipe.fileHandleForReading.close()

        let outcome = await BoundedCall.resultOnItsOwnThread {
            Result { try DescriptorWrite.allBytes(Data("lost".utf8), to: descriptor) }
        }

        let written = try #require(outcome)
        let error = #expect(throws: POSIXError.self) {
            try written.get()
        }
        #expect(error?.code == .EPIPE)
    }
}
