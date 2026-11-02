import Foundation
import TableProWireIO

public actor SseDecoder {
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    private var buffer = ByteQueue()
    // The front of the buffer already searched for a line break, so a line split over many chunks is scanned once.
    private var searchedCount = 0
    private var pendingEvent: String?
    private var pendingId: String?
    private var pendingRetry: Int?
    private var pendingDataLines: [String] = []
    private var hasPendingFields = false

    public init() {}

    public func feed(_ chunk: Data) -> [SseFrame] {
        buffer.append(contentsOf: chunk)

        var frames: [SseFrame] = []

        while let line = takeLine() {
            if line.isEmpty {
                if let frame = flushFrame() {
                    frames.append(frame)
                }
                continue
            }
            processLine(line)
        }

        return frames
    }

    private func takeLine() -> String? {
        let count = buffer.count
        var index = searchedCount
        while index < count {
            switch buffer[index] {
            case Self.lineFeed:
                return removeLine(length: index, terminatorLength: 1)
            case Self.carriageReturn:
                // A carriage return at the end of what has arrived may be the first half of a CRLF.
                guard index + 1 < count else {
                    searchedCount = index
                    return nil
                }
                return removeLine(length: index, terminatorLength: buffer[index + 1] == Self.lineFeed ? 2 : 1)
            default:
                index += 1
            }
        }
        searchedCount = count
        return nil
    }

    private func removeLine(length: Int, terminatorLength: Int) -> String {
        let line = buffer.removeFirst(length)
        buffer.removeFirst(terminatorLength)
        searchedCount = 0
        return String(bytes: line, encoding: .utf8) ?? ""
    }

    private func processLine(_ line: String) {
        if line.first == ":" {
            return
        }

        let field: String
        let value: String
        if let colonIndex = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colonIndex])
            var rest = line[line.index(after: colonIndex)...]
            if rest.first == " " {
                rest = rest.dropFirst()
            }
            value = String(rest)
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            pendingEvent = value
            hasPendingFields = true
        case "id":
            pendingId = value
            hasPendingFields = true
        case "retry":
            if let number = Int(value) {
                pendingRetry = number
                hasPendingFields = true
            }
        case "data":
            pendingDataLines.append(value)
            hasPendingFields = true
        default:
            break
        }
    }

    private func flushFrame() -> SseFrame? {
        defer { resetPending() }

        guard hasPendingFields else { return nil }
        guard !pendingDataLines.isEmpty else { return nil }

        let data = pendingDataLines.joined(separator: "\n")
        return SseFrame(
            event: pendingEvent,
            id: pendingId,
            data: data,
            retry: pendingRetry
        )
    }

    private func resetPending() {
        pendingEvent = nil
        pendingId = nil
        pendingRetry = nil
        pendingDataLines = []
        hasPendingFields = false
    }
}
