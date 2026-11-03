import Foundation

public enum HttpResponseEvent: Sendable, Equatable {
    case head(status: Int, headers: HttpHeaders)
    case body(Data)
    case end
}

public enum HttpResponseReadError: Error, Equatable, Sendable {
    case malformedHead
    case headTooLarge
    case malformedChunkedBody
    case closedBeforeHead
    case truncatedBody
}

public struct HttpResponseReader: Sendable {
    private enum Phase: Sendable {
        case head
        case fixedLength(remaining: Int)
        case chunked(ChunkedBodyDecoder)
        case untilClose
        case done
    }

    private static let maxHeadBytes = 64 * 1_024
    private static let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

    private var buffer: [UInt8] = []
    private var phase: Phase = .head

    public init() {}

    public var isComplete: Bool {
        if case .done = phase { return true }
        return false
    }

    public mutating func feed(_ data: Data) throws -> [HttpResponseEvent] {
        buffer.append(contentsOf: data)
        return try drain()
    }

    public mutating func finish() throws -> [HttpResponseEvent] {
        switch phase {
        case .head:
            throw HttpResponseReadError.closedBeforeHead
        case .fixedLength, .chunked:
            throw HttpResponseReadError.truncatedBody
        case .untilClose:
            phase = .done
            return [.end]
        case .done:
            return []
        }
    }

    private mutating func drain() throws -> [HttpResponseEvent] {
        var events: [HttpResponseEvent] = []
        while true {
            switch phase {
            case .head:
                guard let end = headEnd() else {
                    guard buffer.count <= Self.maxHeadBytes else { throw HttpResponseReadError.headTooLarge }
                    return events
                }
                let (status, headers) = try Self.parseHead(Array(buffer[0..<end]))
                buffer.removeFirst(end + Self.terminator.count)
                if (100...199).contains(status) { continue }
                events.append(.head(status: status, headers: headers))
                phase = try Self.framing(status: status, headers: headers)
                if case .done = phase {
                    events.append(.end)
                    return events
                }

            case .fixedLength(let remaining):
                guard !buffer.isEmpty else { return events }
                let take = min(remaining, buffer.count)
                events.append(.body(Data(buffer[0..<take])))
                buffer.removeFirst(take)
                if remaining - take == 0 {
                    phase = .done
                    events.append(.end)
                    return events
                }
                phase = .fixedLength(remaining: remaining - take)

            case .chunked(var decoder):
                let outcome: (consumed: Int, isComplete: Bool)
                do {
                    outcome = try decoder.consume(buffer, limit: .max)
                } catch {
                    throw HttpResponseReadError.malformedChunkedBody
                }
                buffer.removeFirst(outcome.consumed)
                let decoded = decoder.takeDecoded()
                if !decoded.isEmpty {
                    events.append(.body(Data(decoded)))
                }
                if outcome.isComplete {
                    phase = .done
                    events.append(.end)
                } else {
                    phase = .chunked(decoder)
                }
                return events

            case .untilClose:
                if !buffer.isEmpty {
                    events.append(.body(Data(buffer)))
                    buffer.removeAll(keepingCapacity: true)
                }
                return events

            case .done:
                return events
            }
        }
    }

    private func headEnd() -> Int? {
        guard buffer.count >= Self.terminator.count else { return nil }
        for start in 0...(buffer.count - Self.terminator.count)
            where buffer[start] == 0x0D && buffer[start + 1] == 0x0A && buffer[start + 2] == 0x0D && buffer[start + 3] == 0x0A {
            return start
        }
        return nil
    }

    private static func framing(status: Int, headers: HttpHeaders) throws -> Phase {
        if status == 204 || status == 304 {
            return .done
        }
        if let encoding = headers.value(for: "Transfer-Encoding") {
            let last = encoding.split(separator: ",").last?.trimmingCharacters(in: .whitespaces).lowercased()
            return last == "chunked" ? .chunked(ChunkedBodyDecoder()) : .untilClose
        }
        if let raw = headers.value(for: "Content-Length") {
            guard let length = Int(raw.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                throw HttpResponseReadError.malformedHead
            }
            return length == 0 ? .done : .fixedLength(remaining: length)
        }
        return .untilClose
    }

    private static func parseHead(_ bytes: [UInt8]) throws -> (Int, HttpHeaders) {
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw HttpResponseReadError.malformedHead }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw HttpResponseReadError.malformedHead }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts[0].hasPrefix("HTTP/1."),
              parts[1].count == 3,
              let status = Int(parts[1]) else {
            throw HttpResponseReadError.malformedHead
        }

        var pairs: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HttpResponseReadError.malformedHead }
            let name = String(line[line.startIndex..<colon])
            guard !name.isEmpty, !name.contains(" ") else { throw HttpResponseReadError.malformedHead }
            pairs.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return (status, HttpHeaders(pairs))
    }
}
