//
//  BridgeStdoutTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

struct BridgeStdoutTests {
    @Test("A line larger than the pipe reaches a non-blocking stdout whole", .timeLimit(.minutes(1)))
    func nonBlockingStdoutGetsTheWholeLine() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1)
        #expect(fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1)
        let payload = Data(repeating: UInt8(ascii: "a"), count: 3 * DescriptorRead.pipeCapacity)
        let logger = RecordingBridgeLogger()
        let stdout = BridgeStdout(handle: pipe.fileHandleForWriting, logger: logger)

        async let drained = BackgroundPipeReader.everything(from: pipe.fileHandleForReading, pausingFirst: 0.2)
        let wrote: Void? = await BoundedCall.result { await stdout.write(payload) }
        try pipe.fileHandleForWriting.close()

        let received = try #require(await drained)
        #expect(wrote != nil)
        #expect(received == payload + Data([0x0A]))
        #expect(logger.entries.isEmpty)
    }

    @Test("A stdout nobody reads says why through the bridge's logger", .timeLimit(.minutes(1)))
    func unwritableStdoutIsLogged() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        #expect(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1)
        try pipe.fileHandleForReading.close()
        let logger = RecordingBridgeLogger()
        let stdout = BridgeStdout(handle: pipe.fileHandleForWriting, logger: logger)

        let wrote: Void? = await BoundedCall.result { await stdout.write(Data("{}".utf8)) }

        #expect(wrote != nil)
        #expect(logger.entries.map(\.level) == [.error])
    }
}
