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
}

public enum HttpRequestParser {
    public static let maxHeaderSize = 16 * 1_024
    public static let maxBodySize = 10 * 1_024 * 1_024

    private static let crlfcrlf: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    private static let lflf: [UInt8] = [0x0A, 0x0A]

    public static func parse(_ buffer: Data) throws -> HttpRequestParseResult {
        let bytes = [UInt8](buffer)

        let crlfTerminator = firstIndex(of: crlfcrlf, in: bytes)
        let lflfTerminator = firstIndex(of: lflf, in: bytes)

        if let lflfIndex = lflfTerminator {
            if let crlfIndex = crlfTerminator {
                if lflfIndex < crlfIndex {
                    throw HttpRequestParseError.nonStrictLineEndings
                }
            } else {
                if lflfIndex <= maxHeaderSize {
                    throw HttpRequestParseError.nonStrictLineEndings
                }
            }
        }

        guard let headerEndIndex = crlfTerminator else {
            if bytes.count > maxHeaderSize {
                throw HttpRequestParseError.headerTooLarge
            }
            return .incomplete
        }

        if headerEndIndex > maxHeaderSize {
            throw HttpRequestParseError.headerTooLarge
        }

        let headerBytes = Array(bytes[0..<headerEndIndex])
        let bodyStartIndex = headerEndIndex + crlfcrlf.count

        let headerLines = try splitStrictCrlf(headerBytes)
        guard let requestLineBytes = headerLines.first else {
            throw HttpRequestParseError.malformedRequestLine
        }

        let (method, path, httpVersion) = try parseRequestLine(requestLineBytes)

        var headerPairs: [(String, String)] = []
        for index in 1..<headerLines.count {
            let line = headerLines[index]
            if line.isEmpty { continue }
            let pair = try parseHeaderLine(line)
            headerPairs.append(pair)
        }

        let headers = HttpHeaders(headerPairs)

        let head = HttpRequestHead(
            method: method,
            path: path,
            httpVersion: httpVersion,
            headers: headers
        )

        let contentLengthValue = headers.value(for: "Content-Length")
        if let contentLengthValue, let contentLength = Int(contentLengthValue.trimmingCharacters(in: .whitespaces)) {
            if contentLength > maxBodySize {
                throw HttpRequestParseError.bodyTooLarge(limit: maxBodySize, actual: contentLength)
            }

            let availableBodyBytes = bytes.count - bodyStartIndex
            if availableBodyBytes < contentLength {
                return .incomplete
            }

            let body = Data(bytes[bodyStartIndex..<(bodyStartIndex + contentLength)])
            let consumed = bodyStartIndex + contentLength
            return .complete(head, body: body, consumedBytes: consumed)
        }

        return .complete(head, body: Data(), consumedBytes: bodyStartIndex)
    }

    private static func splitStrictCrlf(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D {
                let nextIndex = index + 1
                if nextIndex >= bytes.count {
                    throw HttpRequestParseError.malformedHeader
                }
                if bytes[nextIndex] != 0x0A {
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

        let method = HttpMethod(rawValue: methodString)
        return (method, path, version)
    }

    private static func parseHeaderLine(_ bytes: [UInt8]) throws -> (String, String) {
        guard let line = String(bytes: bytes, encoding: .utf8) else {
            throw HttpRequestParseError.malformedHeader
        }

        guard let colonIndex = line.firstIndex(of: ":") else {
            throw HttpRequestParseError.malformedHeader
        }

        let nameSlice = line[line.startIndex..<colonIndex]
        let valueSlice = line[line.index(after: colonIndex)...]

        let name = String(nameSlice)
        if name.isEmpty {
            throw HttpRequestParseError.malformedHeader
        }
        if name.contains(" ") || name.contains("\t") {
            throw HttpRequestParseError.malformedHeader
        }

        let value = valueSlice.trimmingCharacters(in: .whitespaces)
        return (name, value)
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let lastStart = haystack.count - needle.count
        var index = 0
        while index <= lastStart {
            var matched = true
            for offset in 0..<needle.count where haystack[index + offset] != needle[offset] {
                matched = false
                break
            }
            if matched {
                return index
            }
            index += 1
        }
        return nil
    }
}
