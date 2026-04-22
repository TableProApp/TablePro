import Foundation
import os

struct HTTPRequest: Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
        case options = "OPTIONS"
    }

    let method: Method
    let path: String
    let headers: [String: String]
    let body: Data?
}

enum HTTPParseError: Error, Sendable {
    case incomplete
    case malformedRequestLine
    case malformedHeaders
    case unsupportedMethod(String)
    case bodyTooLarge
    case malformedChunkedEncoding
}

enum MCPHTTPParser {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPHTTPParser")

    static let maxBodySize = 10 * 1_024 * 1_024

    static func parse(_ data: Data) -> Result<HTTPRequest, HTTPParseError> {
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let lflf = Data([0x0A, 0x0A])

        let headerEndRange: Range<Data.Index>
        if let range = data.range(of: crlfcrlf) {
            headerEndRange = range
        } else if let range = data.range(of: lflf) {
            headerEndRange = range
        } else {
            return .failure(.incomplete)
        }

        let headerData = data[data.startIndex..<headerEndRange.lowerBound]

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .failure(.malformedHeaders)
        }

        // Normalize \r\n to \n then split
        let normalized = headerString.replacingOccurrences(of: "\r\n", with: "\n")
        let headerLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        guard let firstLine = headerLines.first, !firstLine.isEmpty else {
            return .failure(.malformedRequestLine)
        }

        let requestParts = firstLine.split(separator: " ", maxSplits: 2)

        guard requestParts.count >= 2 else {
            return .failure(.malformedRequestLine)
        }

        let methodString = String(requestParts[0])
        guard let method = HTTPRequest.Method(rawValue: methodString) else {
            return .failure(.unsupportedMethod(methodString))
        }

        let path = String(requestParts[1])

        var headers: [String: String] = [:]
        for i in 1..<headerLines.count {
            let line = headerLines[i]
            if line.isEmpty { continue }
            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[line.startIndex..<colonIndex]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStartIndex = headerEndRange.upperBound
        var body: Data?

        if method == .post {
            if let transferEncoding = headers["transfer-encoding"],
               transferEncoding.lowercased().contains("chunked")
            {
                let bodyData = data[bodyStartIndex...]
                switch decodeChunkedBody(bodyData) {
                case .success(let decoded):
                    if decoded.count > maxBodySize {
                        return .failure(.bodyTooLarge)
                    }
                    body = decoded
                case .failure(let error):
                    return .failure(error)
                }
            } else if let contentLengthStr = headers["content-length"],
                      let contentLength = Int(contentLengthStr)
            {
                if contentLength > maxBodySize {
                    return .failure(.bodyTooLarge)
                }

                let availableBytes = data.count - bodyStartIndex
                if availableBytes < contentLength {
                    return .failure(.incomplete)
                }

                body = data[bodyStartIndex..<(bodyStartIndex + contentLength)]
            }
        }

        return .success(HTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: body
        ))
    }

    // MARK: - Chunked Transfer Encoding

    /// Decode chunked transfer encoding body.
    /// Format: <chunk-size-hex>\r\n<chunk-data>\r\n ... 0\r\n\r\n
    private static func decodeChunkedBody(_ data: Data) -> Result<Data, HTTPParseError> {
        var result = Data()
        var offset = data.startIndex

        while offset < data.endIndex {
            // Find the end of the chunk size line
            guard let lineEnd = findCRLF(in: data, from: offset) else {
                return .failure(.incomplete)
            }

            let sizeData = data[offset..<lineEnd]
            guard let sizeString = String(data: sizeData, encoding: .ascii)?.trimmingCharacters(in: .whitespaces),
                  let chunkSize = UInt(sizeString, radix: 16)
            else {
                return .failure(.malformedChunkedEncoding)
            }

            // Move past the \r\n after chunk size
            let chunkDataStart = lineEnd + 2

            // Terminal chunk
            if chunkSize == 0 {
                return .success(result)
            }

            let chunkDataEnd = chunkDataStart + Int(chunkSize)

            // Check we have enough data for the chunk + trailing \r\n
            guard chunkDataEnd + 2 <= data.endIndex else {
                return .failure(.incomplete)
            }

            // Check accumulated size
            if result.count + Int(chunkSize) > maxBodySize {
                return .failure(.bodyTooLarge)
            }

            result.append(data[chunkDataStart..<chunkDataEnd])

            // Skip past the trailing \r\n after chunk data
            offset = chunkDataEnd + 2
        }

        return .failure(.incomplete)
    }

    /// Find \r\n in data starting from given offset
    private static func findCRLF(in data: Data, from start: Data.Index) -> Data.Index? {
        var i = start
        while i < data.endIndex - 1 {
            if data[i] == 0x0D, data[i + 1] == 0x0A {
                return i
            }
            i += 1
        }
        return nil
    }

    // MARK: - Response Building

    static func buildResponse(
        status: Int,
        statusText: String,
        headers: [(String, String)],
        body: Data?
    ) -> Data {
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        if let body {
            response += "Content-Length: \(body.count)\r\n"
        }
        response += "\r\n"
        var data = Data(response.utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    static func buildSSEHeaders(sessionId: String, corsHeaders: [(String, String)] = []) -> Data {
        var response = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "Mcp-Session-Id: \(sessionId)\r\n"
        for (key, value) in corsHeaders {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        return Data(response.utf8)
    }

    static func buildSSEEvent(data: Data, id: String? = nil) -> Data {
        var event = Data()
        if let id {
            event.append(Data("id: \(id)\n".utf8))
        }
        event.append(Data("data: ".utf8))
        event.append(data)
        event.append(Data("\n\n".utf8))
        return event
    }

    static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 413: return "Content Too Large"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
