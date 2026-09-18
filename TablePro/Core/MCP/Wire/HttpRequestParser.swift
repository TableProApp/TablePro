import Foundation

public enum HttpRequestParseResult: Sendable, Equatable {
    case incomplete
    case complete(HttpRequestHead, body: Data, consumedBytes: Int)
}

public enum HttpRequestParseError: Error, Equatable, Sendable {
    case malformedRequestLine
    case malformedHeader
    case unsupportedHttpVersion(String)
    case missingHostHeader
    case bodyTooLarge(limit: Int, actual: Int)
    case nonStrictLineEndings
    case headerTooLarge
    case unsupportedTransferEncoding(String)
    case malformedChunkedBody
}

public struct HttpParserLimits: Sendable, Equatable {
    public let maxHeaderBytes: Int
    public let maxBodyBytes: Int

    public init(maxHeaderBytes: Int, maxBodyBytes: Int) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    public static let standard = HttpParserLimits(
        maxHeaderBytes: 16 * 1_024,
        maxBodyBytes: 10 * 1_024 * 1_024
    )
}

public struct HttpRequestStreamParser: Sendable {
    private enum Phase: Sendable {
        case head
        case fixedBody(HttpRequestHead, length: Int)
        case chunkedBody(HttpRequestHead, ChunkedBodyDecoder)
    }

    private let limits: HttpParserLimits
    private var buffer: [UInt8] = []
    private var scanCursor = 0
    private var phase: Phase = .head

    public init(limits: HttpParserLimits = .standard) {
        self.limits = limits
    }

    public var pendingByteCount: Int {
        buffer.count
    }

    public var isBetweenRequests: Bool {
        if case .head = phase { return buffer.isEmpty }
        return false
    }

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    public mutating func next() throws -> HttpParsedRequest? {
        switch phase {
        case .head:
            return try parseHeadPhase()
        case .fixedBody(let head, let length):
            return try parseFixedBody(head: head, length: length)
        case .chunkedBody(let head, let decoder):
            return try parseChunkedBody(head: head, decoder: decoder)
        }
    }

    private mutating func parseHeadPhase() throws -> HttpParsedRequest? {
        skipLeadingCrlf()
        guard let terminator = try scanHeaderTerminator() else {
            if buffer.count > limits.maxHeaderBytes {
                throw HttpRequestParseError.headerTooLarge
            }
            return nil
        }
        if terminator > limits.maxHeaderBytes {
            throw HttpRequestParseError.headerTooLarge
        }
        let headBytes = Array(buffer[0..<terminator])
        let head = try Self.decodeHead(headBytes)
        discard(terminator + 4)
        return try beginBody(for: head)
    }

    private mutating func beginBody(for head: HttpRequestHead) throws -> HttpParsedRequest? {
        if let encoding = head.headers.value(for: "Transfer-Encoding") {
            let coding = encoding.trimmingCharacters(in: .whitespaces).lowercased()
            guard coding == "chunked" else {
                throw HttpRequestParseError.unsupportedTransferEncoding(encoding)
            }
            guard head.headers.values(for: "Content-Length").isEmpty else {
                throw HttpRequestParseError.malformedHeader
            }
            phase = .chunkedBody(head, ChunkedBodyDecoder())
            return try next()
        }

        let contentLengths = head.headers.values(for: "Content-Length")
        guard contentLengths.count <= 1 else {
            throw HttpRequestParseError.malformedHeader
        }
        if let raw = contentLengths.first {
            guard let length = Int(raw.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                throw HttpRequestParseError.malformedHeader
            }
            guard length <= limits.maxBodyBytes else {
                throw HttpRequestParseError.bodyTooLarge(limit: limits.maxBodyBytes, actual: length)
            }
            phase = .fixedBody(head, length: length)
            return try next()
        }

        phase = .head
        return HttpParsedRequest(head: head, body: Data())
    }

    private mutating func parseFixedBody(head: HttpRequestHead, length: Int) throws -> HttpParsedRequest? {
        guard buffer.count >= length else { return nil }
        let body = Data(buffer[0..<length])
        discard(length)
        phase = .head
        return HttpParsedRequest(head: head, body: body)
    }

    private mutating func parseChunkedBody(
        head: HttpRequestHead,
        decoder: ChunkedBodyDecoder
    ) throws -> HttpParsedRequest? {
        var working = decoder
        let outcome = try working.consume(buffer, limit: limits.maxBodyBytes)
        discard(outcome.consumed)
        guard outcome.isComplete else {
            phase = .chunkedBody(head, working)
            return nil
        }
        phase = .head
        return HttpParsedRequest(head: head, body: Data(working.decoded))
    }

    private mutating func skipLeadingCrlf() {
        var stripped = 0
        while stripped < 2, buffer.count >= 4, buffer[0] == 0x0D, buffer[1] == 0x0A,
              !(buffer[2] == 0x0D && buffer[3] == 0x0A) {
            discard(2)
            stripped += 1
        }
    }

    private mutating func scanHeaderTerminator() throws -> Int? {
        var index = scanCursor
        while index < buffer.count {
            if buffer[index] == 0x0A {
                guard index > 0, buffer[index - 1] == 0x0D else {
                    throw HttpRequestParseError.nonStrictLineEndings
                }
                if index >= 3, buffer[index - 2] == 0x0A, buffer[index - 3] == 0x0D {
                    scanCursor = index + 1
                    return index - 3
                }
            }
            index += 1
        }
        scanCursor = index
        return nil
    }

    private mutating func discard(_ count: Int) {
        guard count > 0 else { return }
        buffer.removeFirst(min(count, buffer.count))
        scanCursor = max(0, scanCursor - count)
    }

    private static func decodeHead(_ bytes: [UInt8]) throws -> HttpRequestHead {
        let lines = try splitStrictCrlf(bytes)
        guard let requestLine = lines.first else {
            throw HttpRequestParseError.malformedRequestLine
        }

        let (method, path, httpVersion) = try parseRequestLine(requestLine)

        var headerPairs: [(String, String)] = []
        for index in 1..<lines.count where !lines[index].isEmpty {
            headerPairs.append(try parseHeaderLine(lines[index]))
        }
        let headers = HttpHeaders(headerPairs)

        let hosts = headers.values(for: "Host")
        guard hosts.count <= 1 else {
            throw HttpRequestParseError.malformedHeader
        }
        if httpVersion == "HTTP/1.1", hosts.isEmpty {
            throw HttpRequestParseError.missingHostHeader
        }

        return HttpRequestHead(method: method, path: path, httpVersion: httpVersion, headers: headers)
    }

    private static func splitStrictCrlf(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D {
                let nextIndex = index + 1
                guard nextIndex < bytes.count, bytes[nextIndex] == 0x0A else {
                    throw HttpRequestParseError.malformedHeader
                }
                lines.append(current)
                current = []
                index = nextIndex + 1
                continue
            }
            if byte == 0x0A {
                throw HttpRequestParseError.nonStrictLineEndings
            }
            current.append(byte)
            index += 1
        }
        lines.append(current)
        return lines
    }

    private static func parseRequestLine(_ bytes: [UInt8]) throws -> (HttpMethod, String, String) {
        guard let line = String(bytes: bytes, encoding: .utf8) else {
            throw HttpRequestParseError.malformedRequestLine
        }

        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw HttpRequestParseError.malformedRequestLine
        }

        let methodString = String(parts[0])
        let path = String(parts[1])
        let version = String(parts[2])

        guard !methodString.isEmpty, !path.isEmpty, !version.isEmpty else {
            throw HttpRequestParseError.malformedRequestLine
        }
        guard version.hasPrefix("HTTP/") else {
            throw HttpRequestParseError.unsupportedHttpVersion(version)
        }

        return (HttpMethod(rawValue: methodString), path, version)
    }

    private static func parseHeaderLine(_ bytes: [UInt8]) throws -> (String, String) {
        guard let line = String(bytes: bytes, encoding: .utf8) else {
            throw HttpRequestParseError.malformedHeader
        }
        guard let colonIndex = line.firstIndex(of: ":") else {
            throw HttpRequestParseError.malformedHeader
        }

        let name = String(line[line.startIndex..<colonIndex])
        guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else {
            throw HttpRequestParseError.malformedHeader
        }

        let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        return (name, value)
    }
}

struct ChunkedBodyDecoder: Sendable {
    private enum State: Sendable {
        case size
        case data(remaining: Int)
        case dataTerminator
        case trailer
    }

    private static let maxLineBytes = 4_096

    private(set) var decoded: [UInt8] = []
    private var state: State = .size

    mutating func consume(_ buffer: [UInt8], limit: Int) throws -> (consumed: Int, isComplete: Bool) {
        var cursor = 0
        while true {
            switch state {
            case .size:
                guard let lineEnd = try Self.findCrlf(buffer, from: cursor) else {
                    guard buffer.count - cursor <= Self.maxLineBytes else {
                        throw HttpRequestParseError.malformedChunkedBody
                    }
                    return (cursor, false)
                }
                let size = try Self.parseChunkSize(Array(buffer[cursor..<lineEnd]), limit: limit)
                cursor = lineEnd + 2
                state = size == 0 ? .trailer : .data(remaining: size)

            case .data(let remaining):
                let available = buffer.count - cursor
                guard available > 0 else { return (cursor, false) }
                let take = min(remaining, available)
                guard decoded.count + take <= limit else {
                    throw HttpRequestParseError.bodyTooLarge(limit: limit, actual: decoded.count + take)
                }
                decoded.append(contentsOf: buffer[cursor..<(cursor + take)])
                cursor += take
                let left = remaining - take
                state = left == 0 ? .dataTerminator : .data(remaining: left)

            case .dataTerminator:
                guard buffer.count - cursor >= 2 else { return (cursor, false) }
                guard buffer[cursor] == 0x0D, buffer[cursor + 1] == 0x0A else {
                    throw HttpRequestParseError.malformedChunkedBody
                }
                cursor += 2
                state = .size

            case .trailer:
                guard let lineEnd = try Self.findCrlf(buffer, from: cursor) else {
                    guard buffer.count - cursor <= Self.maxLineBytes else {
                        throw HttpRequestParseError.malformedChunkedBody
                    }
                    return (cursor, false)
                }
                let isFinalLine = lineEnd == cursor
                cursor = lineEnd + 2
                if isFinalLine { return (cursor, true) }
            }
        }
    }

    private static func findCrlf(_ buffer: [UInt8], from start: Int) throws -> Int? {
        var index = start
        while index < buffer.count {
            if buffer[index] == 0x0A {
                guard index > start, buffer[index - 1] == 0x0D else {
                    throw HttpRequestParseError.malformedChunkedBody
                }
                return index - 1
            }
            index += 1
        }
        return nil
    }

    private static func parseChunkSize(_ bytes: [UInt8], limit: Int) throws -> Int {
        guard let line = String(bytes: bytes, encoding: .utf8) else {
            throw HttpRequestParseError.malformedChunkedBody
        }
        let digits = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.count <= 8, let size = Int(digits, radix: 16), size >= 0 else {
            throw HttpRequestParseError.malformedChunkedBody
        }
        guard size <= limit else {
            throw HttpRequestParseError.bodyTooLarge(limit: limit, actual: size)
        }
        return size
    }
}

public enum HttpRequestParser {
    public static let maxHeaderSize = HttpParserLimits.standard.maxHeaderBytes
    public static let maxBodySize = HttpParserLimits.standard.maxBodyBytes

    public static func parse(
        _ buffer: Data,
        limits: HttpParserLimits = .standard
    ) throws -> HttpRequestParseResult {
        var parser = HttpRequestStreamParser(limits: limits)
        parser.append(buffer)
        guard let request = try parser.next() else { return .incomplete }
        return .complete(request.head, body: request.body, consumedBytes: buffer.count - parser.pendingByteCount)
    }
}
