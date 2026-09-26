//
//  BridgeStdinTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

struct BridgeStdinTests {
    private static func everyLine(of stream: AsyncStream<Data>) async -> [Data]? {
        await BoundedCall.result {
            var lines: [Data] = []
            for await line in stream {
                lines.append(line)
            }
            return lines
        }
    }

    @Test("A non-blocking stdin keeps the session reading until the host closes it", .timeLimit(.minutes(1)))
    func nonBlockingStdinReadsUntilEndOfFile() async {
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1)
        BackgroundPipeWriter.write(
            [Data("{\"id\":1}\n".utf8), Data("{\"id\":2}\n".utf8)],
            to: pipe.fileHandleForWriting,
            pausingBeforeEach: 0.2
        )
        let logger = RecordingBridgeLogger()

        let lines = await Self.everyLine(of: BridgeStdin.lines(from: pipe.fileHandleForReading, logger: logger))

        #expect(lines == [Data("{\"id\":1}".utf8), Data("{\"id\":2}".utf8)])
        #expect(logger.entries.isEmpty)
    }

    @Test("A stdin that cannot be read ends the session and says why", .timeLimit(.minutes(1)))
    func unreadableStdinEndsTheSession() async throws {
        let descriptor = open(FileManager.default.temporaryDirectory.path, O_RDONLY)
        try #require(descriptor >= 0)
        let directory = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let logger = RecordingBridgeLogger()

        let lines = await Self.everyLine(of: BridgeStdin.lines(from: directory, logger: logger))

        #expect(lines?.isEmpty == true)
        #expect(logger.entries.map(\.level) == [.error])
    }
}
