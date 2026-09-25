//
//  DescriptorReadTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

struct DescriptorReadTests {
    @Test("A read returns what has arrived without waiting for the rest")
    func returnsWhatHasArrived() throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        try pipe.fileHandleForWriting.write(contentsOf: Data("first".utf8))

        let bytes = try DescriptorRead.availableBytes(from: pipe.fileHandleForReading.fileDescriptor)

        #expect(bytes == Data("first".utf8))
    }

    @Test("A read takes no more than its limit")
    func stopsAtTheLimit() throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        try pipe.fileHandleForWriting.write(contentsOf: Data("abcdef".utf8))
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

    @Test("An empty non-blocking pipe is a thrown EAGAIN, the read that raised in a dump's stderr callback")
    func emptyNonBlockingPipeThrows() throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1)

        let error = #expect(throws: POSIXError.self) {
            try DescriptorRead.availableBytes(from: descriptor)
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

    /// End of file comes once every holder of the write end has let go, and a child this process is
    /// spawning at that moment briefly holds it too. Measured: with four threads launching
    /// `/usr/bin/true`, 14 of 20,000 closes were not yet end of file at once, and 0 of 20,000
    /// without them; beside the other process suites here, 9 of 200 were not, and all 200 were
    /// 200ms later. So the last check waits for it rather than expecting it on the spot.
    @Test("Only a pipe holding bytes or at end of file reads without waiting", .timeLimit(.minutes(1)))
    func readinessFollowsThePipe() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        #expect(!DescriptorRead.hasInputWithoutWaiting(descriptor))

        try pipe.fileHandleForWriting.write(contentsOf: Data("x".utf8))
        #expect(DescriptorRead.hasInputWithoutWaiting(descriptor))

        _ = try DescriptorRead.availableBytes(from: descriptor)
        #expect(!DescriptorRead.hasInputWithoutWaiting(descriptor))

        try pipe.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(10)
        while !DescriptorRead.hasInputWithoutWaiting(descriptor), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(DescriptorRead.hasInputWithoutWaiting(descriptor))
    }
}
