//
//  MCPRemoteServerTransport.swift
//  TablePro
//

import Foundation
import os

/// Streamable HTTP to an MCP server somebody else runs.
///
/// Separate from `MCPStreamableHttpClientTransport`, which talks to TablePro's own bridge and is
/// shaped for it: that one sends `Mcp-Method` and `Mcp-Name` headers no third-party server
/// understands, requires a bearer token, keeps one shared inbound stream that a caller has to
/// correlate by JSON-RPC id, and reports an unreachable host as "TablePro's MCP server is not
/// reachable", which is the wrong sentence about somebody else's machine.
///
/// The shape here is request and response, because that is what the specification describes: a POST
/// carrying one request is answered by that request's response, either as `application/json` or as
/// an event stream ending in it. So there is no id correlation to do and no reader task to own, and
/// a call that fails fails on the call rather than somewhere else.
internal actor MCPRemoteServerTransport {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MCPRemoteTransport")

    /// The header the specification names for a server that keeps state between requests. Captured
    /// from whatever answers `initialize` and sent on every request afterwards; a server that
    /// returns none is stateless and is never sent one.
    private static let sessionIdHeader = "Mcp-Session-Id"

    private let endpoint: URL
    private let bearerToken: String
    private let urlSession: URLSession
    private let timeout: Duration

    private var negotiatedSessionId: String?
    /// What the server agreed to, which starts as what TablePro asks for and is replaced by the
    /// initialize response. Sent on every request from then on.
    private var protocolVersion: MCPProtocolVersion = .latest
    private var isClosed = false

    internal init(
        endpoint: URL,
        bearerToken: String,
        timeout: Duration,
        urlSession: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.timeout = timeout
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = TimeInterval(timeout.components.seconds)
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            self.urlSession = URLSession(configuration: configuration)
        }
    }

    /// Takes the version the server chose during initialization. Ignored when the server names one
    /// TablePro does not implement, because sending back a version this client cannot speak is
    /// worse than continuing to name the one it can.
    internal func adopt(protocolVersion negotiated: MCPProtocolVersion) {
        guard negotiated.isSupported else { return }
        protocolVersion = negotiated
    }

    /// Sends one request and returns its response payload.
    ///
    /// `isInitialize` is what allows the session header to be captured, because that is the one
    /// exchange the specification lets a server issue it on.
    internal func send(request body: Data, isInitialize: Bool = false) async throws -> JsonValue {
        guard !isClosed else { throw MCPClientError.transport(Self.closedMessage) }
        let (head, payload) = try await perform(body: body, expectsResponse: true)

        if isInitialize, let issued = head.value(forHTTPHeaderField: Self.sessionIdHeader), !issued.isEmpty {
            negotiatedSessionId = issued
        }
        guard let payload else { throw MCPClientError.malformedResponse }
        return try Self.result(from: payload)
    }

    /// Sends one notification. A notification has no response, and the specification answers it with
    /// `202 Accepted` and an empty body, so nothing is decoded and nothing is waited for beyond the
    /// server acknowledging it.
    internal func send(notification body: Data) async throws {
        guard !isClosed else { throw MCPClientError.transport(Self.closedMessage) }
        _ = try await perform(body: body, expectsResponse: false)
    }

    /// Ends the session. A server that issued a session id is told to drop it, per the
    /// specification's `DELETE`; one that never issued one has nothing to end. A server that does
    /// not implement `DELETE` answers 405, which is not an error worth reporting to anybody.
    internal func close() async {
        guard !isClosed else { return }
        isClosed = true
        defer { urlSession.invalidateAndCancel() }
        guard negotiatedSessionId != nil else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        applyCommonHeaders(to: &request)
        _ = try? await urlSession.data(for: request)
    }

    // MARK: - HTTP

    private func perform(body: Data, expectsResponse: Bool) async throws -> (HTTPURLResponse, Data?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = TimeInterval(timeout.components.seconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        applyCommonHeaders(to: &request)

        /// Read incrementally rather than with `data(for:)`.
        ///
        /// The specification says a server SHOULD close the event stream once it has sent the
        /// response, which is not MUST, and several do not: they leave it open for the
        /// notifications a later request might produce. `data(for:)` returns only when the body
        /// ends, so against one of those every single call would sit until the timeout and then
        /// fail, having already been answered. Reading line by line lets the call return on the
        /// response frame and drop the rest of the stream.
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw MCPClientError.timedOut
        } catch {
            throw MCPClientError.transport(error.localizedDescription)
        }

        guard let head = response as? HTTPURLResponse else { throw MCPClientError.malformedResponse }

        /// A session the server has forgotten is reported as 404 on a request that carried one. The
        /// id is dropped so the next call initializes again rather than repeating a request the
        /// server will keep refusing.
        if head.statusCode == 404, negotiatedSessionId != nil {
            negotiatedSessionId = nil
            throw MCPClientError.sessionExpired
        }
        guard (200..<300).contains(head.statusCode) else {
            /// A body that will not read is not the error worth reporting. The status already says
            /// what happened, and letting a read failure propagate would turn "the server rejected
            /// TablePro's credential" into a transport message about the sentence explaining it.
            let detail = (try? await Self.collect(bytes)) ?? Data()
            throw Self.httpFailure(status: head.statusCode, body: detail)
        }
        guard expectsResponse else { return (head, nil) }

        let contentType = head.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            return (head, try await Self.firstEventPayload(in: bytes))
        }
        return (head, try await Self.collect(bytes))
    }

    /// Caps what a body can cost. A server that answered with a gigabyte would otherwise be read
    /// into memory in full before anything decided the answer was unusable.
    private static let maximumBodyBytes = 8 * 1_024 * 1_024

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maximumBodyBytes { break }
            }
        } catch let error as URLError where error.code == .timedOut {
            throw MCPClientError.timedOut
        } catch {
            throw MCPClientError.transport(error.localizedDescription)
        }
        return data
    }

    private func applyCommonHeaders(to request: inout URLRequest) {
        request.setValue(protocolVersion.rawValue, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let negotiatedSessionId {
            request.setValue(negotiatedSessionId, forHTTPHeaderField: Self.sessionIdHeader)
        }
    }

    // MARK: - Decoding

    /// The first event carrying a JSON-RPC response, and then the stream is let go.
    ///
    /// A server may send progress notifications ahead of the answer on the same stream, so the
    /// stream is read past anything that is not a response rather than the first event being
    /// assumed to be it. Returning ends the iteration, which cancels the underlying task, so a
    /// stream the server never closes costs nothing once the answer is in.
    private static func firstEventPayload(in bytes: URLSession.AsyncBytes) async throws -> Data {
        let decoder = SseDecoder()
        /// Fed as raw bytes rather than through `AsyncBytes.lines`, which drops empty lines. A blank
        /// line is what terminates an SSE event, so a decoder that never sees one never flushes a
        /// frame and the response is never found.
        var chunk = Data()
        do {
            for try await byte in bytes {
                chunk.append(byte)
                /// A stream that never sends a newline would otherwise grow this without bound for
                /// as long as the request timeout allows. One line of an event is not megabytes.
                if chunk.count > maximumBodyBytes { throw MCPClientError.malformedResponse }
                guard byte == 0x0A else { continue }
                let frames = await decoder.feed(chunk)
                chunk.removeAll(keepingCapacity: true)
                for frame in frames {
                    guard let payload = frame.data.data(using: .utf8),
                          let message = try? JsonRpcCodec.decode(payload)
                    else { continue }
                    switch message {
                    case .successResponse, .errorResponse:
                        return payload
                    case .request, .notification:
                        continue
                    }
                }
            }
        } catch let error as URLError where error.code == .timedOut {
            throw MCPClientError.timedOut
        } catch {
            throw MCPClientError.transport(error.localizedDescription)
        }
        throw MCPClientError.malformedResponse
    }

    private static func result(from payload: Data) throws -> JsonValue {
        guard let message = try? JsonRpcCodec.decode(payload) else {
            throw MCPClientError.malformedResponse
        }
        switch message {
        case .successResponse(let response):
            return response.result
        case .errorResponse(let response):
            throw MCPClientError.server(code: response.error.code, message: response.error.message)
        case .request, .notification:
            /// A server-initiated request is not answered. TablePro is the client here, and a client
            /// that served a sampling or elicitation request would be letting the server drive the
            /// session, which is what the approval gate exists to prevent.
            logger.debug("Ignoring a server-initiated message from an outside MCP server")
            throw MCPClientError.malformedResponse
        }
    }

    /// Every status the user could act on gets its own sentence. The rest carry the server's own
    /// body, which is more use than a status number on its own.
    private static func httpFailure(status: Int, body: Data) -> MCPClientError {
        switch status {
        case 401, 403:
            return .transport(String(localized: "The server rejected TablePro's credential."))
        case 404:
            return .transport(String(localized: "The server has no MCP endpoint at that address."))
        case 405:
            return .transport(String(localized: "The address does not accept MCP requests."))
        case 429:
            return .transport(String(localized: "The server is rate limiting TablePro. Try again shortly."))
        case 500...599:
            return .transport(String(localized: "The server reported an error."))
        default:
            let detail = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let detail, !detail.isEmpty else {
                return .transport(
                    String(format: String(localized: "The server answered with HTTP %d."), status)
                )
            }
            return .transport(detail)
        }
    }

    private static var closedMessage: String {
        String(localized: "The connection to the server was closed.")
    }
}
