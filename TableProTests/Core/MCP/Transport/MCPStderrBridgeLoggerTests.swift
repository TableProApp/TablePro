//
//  MCPStderrBridgeLoggerTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

struct MCPStderrBridgeLoggerTests {
    private static func fill(_ descriptor: Int32) -> Int {
        let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: DescriptorRead.pipeCapacity)
        var total = 0
        while true {
            let written = chunk.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard written > 0 else { return total }
            total += written
        }
    }

    @Test("A log line waits for room on a full non-blocking stderr", .timeLimit(.minutes(1)))
    func fullNonBlockingStderrGetsTheLine() async throws {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1)
        #expect(fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1)
        let filled = Self.fill(descriptor)
        #expect(filled > 0)
        let logger = MCPStderrBridgeLogger(descriptor: descriptor)

        async let drained = BackgroundPipeReader.everything(from: pipe.fileHandleForReading, pausingFirst: 0.2)
        let logged: Void? = await BoundedCall.resultOnItsOwnThread {
            logger.log(.error, "Upstream stream ended")
        }
        try pipe.fileHandleForWriting.close()

        let received = try #require(await drained)
        let line = Data("[error] Upstream stream ended\n".utf8)
        #expect(logged != nil)
        #expect(received.count == filled + line.count)
        #expect(received.suffix(line.count) == line)
    }
}
