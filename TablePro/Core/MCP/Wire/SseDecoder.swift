import Foundation

public actor SseDecoder {
    private var buffer: Data
    private var pendingEvent: String?
    private var pendingId: String?
    private var pendingRetry: Int?
    private var pendingDataLines: [String]
    private var hasPendingFields: Bool

    public init() {
        buffer = Data()
        pendingEvent = nil
        pendingId = nil
        pendingRetry = nil
        pendingDataLines = []
        hasPendingFields = false
    }

    public func feed(_ chunk: Data) -> [SseFrame] {
        buffer.append(chunk)

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
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let byte = buffer[index]
            if byte == 0x0A {
                let lineData = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                return decodeLine(lineData)
            }
            if byte == 0x0D {
                let lineData = buffer[buffer.startIndex..<index]
                let nextIndex = buffer.index(after: index)
                if nextIndex < buffer.endIndex, buffer[nextIndex] == 0x0A {
                    buffer.removeSubrange(buffer.startIndex...nextIndex)
                } else if nextIndex == buffer.endIndex {
                    return nil
                } else {
                    buffer.removeSubrange(buffer.startIndex...index)
                }
                return decodeLine(lineData)
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    private func decodeLine(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
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
