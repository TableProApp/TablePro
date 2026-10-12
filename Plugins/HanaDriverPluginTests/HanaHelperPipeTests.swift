import Darwin
import Foundation
import XCTest

final class HanaHelperPipeTests: XCTestCase {
    func testWritingToAPipeNobodyReadsIsAnErrorAndNotASignal() throws {
        let pipe = Pipe()
        try HanaHelperPipe.suppressBrokenPipeSignal(on: pipe.fileHandleForWriting.fileDescriptor)
        try pipe.fileHandleForReading.close()

        XCTAssertThrowsError(try HanaHelperPipe.write(Data("frame".utf8), to: pipe.fileHandleForWriting.fileDescriptor)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EPIPE)
        }
    }

    func testReadingExactlyWaitsForEveryByte() throws {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading.fileDescriptor
        let writer = pipe.fileHandleForWriting
        DispatchQueue.global().async {
            for chunk in ["ab", "cd", "e"] {
                try? HanaHelperPipe.write(Data(chunk.utf8), to: writer.fileDescriptor)
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        XCTAssertEqual(try HanaHelperPipe.read(exactly: 5, from: reader), .complete(Data("abcde".utf8)))
        try writer.close()
    }

    func testAFrameLargerThanOneChunkCrossesThePipeIntact() throws {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading.fileDescriptor
        let writer = pipe.fileHandleForWriting
        let count = HanaHelperPipe.maximumChunkByteCount * 2 + 12_345
        let block = Data((0..<65_521).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var pattern = Data()
        while pattern.count < count {
            pattern.append(block)
        }
        let payload = Data(pattern.prefix(count))
        DispatchQueue.global().async {
            try? HanaHelperPipe.write(payload, to: writer.fileDescriptor)
            try? writer.close()
        }

        let received = try HanaHelperPipe.read(exactly: count, from: reader)

        XCTAssertEqual(received, .complete(payload))
        XCTAssertEqual(try HanaHelperPipe.read(exactly: 1, from: reader), .endOfStream(receivedByteCount: 0))
    }

    func testReadingReportsHowFarTheStreamGotBeforeItEnded() throws {
        let pipe = Pipe()
        try HanaHelperPipe.write(Data("abc".utf8), to: pipe.fileHandleForWriting.fileDescriptor)
        try pipe.fileHandleForWriting.close()
        let reader = pipe.fileHandleForReading.fileDescriptor

        XCTAssertEqual(try HanaHelperPipe.read(exactly: 13, from: reader), .endOfStream(receivedByteCount: 3))
        XCTAssertEqual(try HanaHelperPipe.read(exactly: 13, from: reader), .endOfStream(receivedByteCount: 0))
    }

    func testReadingNothingNeedsNoBytes() throws {
        let pipe = Pipe()

        XCTAssertEqual(try HanaHelperPipe.read(exactly: 0, from: pipe.fileHandleForReading.fileDescriptor), .complete(Data()))
    }
}
