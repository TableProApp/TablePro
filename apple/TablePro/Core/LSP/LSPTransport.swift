//
//  LSPTransport.swift
//  TablePro
//

import Foundation
import os
import TableProProcess

// MARK: - LSPTransportError

enum LSPTransportError: Error, LocalizedError {
    case processNotRunning
    case processExited(Int32)
    case invalidResponse
    case requestCancelled
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return String(localized: "LSP process is not running")
        case .processExited(let code):
            return String(format: String(localized: "LSP process exited with code %d"), code)
        case .invalidResponse:
            return String(localized: "Invalid LSP response")
        case .requestCancelled:
            return String(localized: "LSP request was cancelled")
        case .serverError(let code, let message):
            return String(format: String(localized: "LSP server error (%d): %@"), code, message)
        }
    }
}

// MARK: - LSPMessageWriter

// Writes on its own queue, so a server that stops reading blocks the queue and never the transport.
final class LSPMessageWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.TablePro.LSPTransport.writer")
    private var isClosed = false

    init(_ handle: FileHandle) throws {
        // Without it, a write to a server that has exited raises SIGPIPE and ends the app.
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.handle = handle
    }

    func write(_ frame: Data, onFailure: @escaping @Sendable (any Error) -> Void) {
        queue.async { [self] in
            guard !isClosed else {
                onFailure(LSPTransportError.processNotRunning)
                return
            }
            do {
                try handle.write(contentsOf: frame)
            } catch {
                onFailure(error)
            }
        }
    }

    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            try? handle.close()
        }
    }
}

// MARK: - LSPTransport

actor LSPTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LSPTransport")

    private var process: Process?
    private var stdinPipe: Pipe?
    private var writer: LSPMessageWriter?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stderrReader: PipeReader?
    private var stdoutReader: PipeReader?
    private var nextRequestID: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var notificationHandlers: [String: @Sendable (Data) -> Void] = [:]
    private var requestHandlers: [String: @Sendable (Data) -> Any?] = [:]
    private var deferredRequestHandlers: [String: @Sendable (Data, Int) -> Void] = [:]
    private var readerTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start(executablePath: String, arguments: [String] = [], environment: [String: String]? = nil) throws {
        // Inherited: behind a proxy the server needs HTTPS_PROXY and NODE_EXTRA_CA_CERTS from the user.
        let proc = try ProcessLauncher.process(for: ProcessCommand(
            executable: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            environment: ProcessEnvironment.inherited().merging(environment ?? [:]) { _, override in override }
        ))

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.writer = try LSPMessageWriter(stdin.fileHandleForWriting)
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc

        proc.terminationHandler = { [weak self] terminatedProcess in
            let code = terminatedProcess.terminationStatus
            Task { [weak self] in
                await self?.handleProcessExit(code: code)
            }
        }

        let stderrReader = PipeReader(stderr.fileHandleForReading)
        stderrReader.start { data in
            guard let text = String(data: data, encoding: .utf8) else { return }
            Self.logger.debug("LSP stderr: \(text)")
        }
        self.stderrReader = stderrReader

        try proc.run()

        // Not FileHandle.bytes: its reads share one serial queue, so this idle server would hold every
        // other AsyncBytes reader in the app, the Claude Agent chat among them.
        let (chunks, chunkSink) = AsyncStream<Data>.makeStream()
        let stdoutReader = PipeReader(stdout.fileHandleForReading)
        stdoutReader.start(delivering: { chunkSink.yield($0) }, onEnd: { chunkSink.finish() })
        self.stdoutReader = stdoutReader
        readerTask = Task { [weak self] in
            await self?.runReadLoop(chunks)
        }

        Self.logger.info("LSP transport started: \(executablePath)")
    }

    func stop() async {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: LSPTransportError.requestCancelled)
        }

        readerTask?.cancel()
        readerTask = nil

        writer?.close()
        writer = nil
        stdoutReader?.stop()
        stdoutReader = nil
        if let stdoutHandle = stdoutPipe?.fileHandleForReading {
            try? stdoutHandle.close()
        }
        stderrReader?.stop()
        stderrReader = nil
        if let stderrHandle = stderrPipe?.fileHandleForReading {
            try? stderrHandle.close()
        }

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        Self.logger.info("LSP transport stopped")
    }

    // MARK: - Send Request

    func sendRequest<P: Encodable>(method: String, params: P?) async throws -> Data {
        guard let process, process.isRunning else {
            throw LSPTransportError.processNotRunning
        }

        let requestID = nextRequestID
        nextRequestID += 1

        let request = LSPJSONRPCRequest(id: requestID, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            do {
                try writeMessage(data, failingRequest: requestID)
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Send Notification

    func sendNotification<P: Encodable>(method: String, params: P?) throws {
        guard let process, process.isRunning else {
            throw LSPTransportError.processNotRunning
        }

        let notification = LSPJSONRPCNotification(method: method, params: params)
        let data = try JSONEncoder().encode(notification)
        try writeMessage(data)
    }

    // MARK: - Cancel Request

    func cancelRequest(id: Int) {
        let params: [String: Int] = ["id": id]
        do {
            let data = try JSONEncoder().encode(LSPJSONRPCNotification(method: "$/cancelRequest", params: params))
            try writeMessage(data)
        } catch {
            Self.logger.warning("LSP cancelRequest \(id) failed to send: \(error.localizedDescription); resolving local pending entry")
            if let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: - Notification Handlers

    func onNotification(method: String, handler: @escaping @Sendable (Data) -> Void) {
        notificationHandlers[method] = handler
    }

    func onRequest(method: String, handler: @escaping @Sendable (Data) -> Any?) {
        requestHandlers[method] = handler
    }

    func onDeferredRequest(method: String, handler: @escaping @Sendable (Data, Int) -> Void) {
        deferredRequestHandlers[method] = handler
    }

    func sendDeferredResponse<R: Encodable>(id: Int, result: R) async throws {
        let resultData = try JSONEncoder().encode(result)
        let resultObj = try JSONSerialization.jsonObject(with: resultData)
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": resultObj]
        let data = try JSONSerialization.data(withJSONObject: response)
        try writeMessage(data)
    }

    func sendDeferredArrayResponse<R: Encodable>(id: Int, result: R) async throws {
        let resultData = try JSONEncoder().encode(result)
        let resultObj = try JSONSerialization.jsonObject(with: resultData)
        let wrapped: [Any] = [resultObj, NSNull()]
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": wrapped]
        let data = try JSONSerialization.data(withJSONObject: response)
        try writeMessage(data)
    }

    // MARK: - Private

    private func writeMessage(_ data: Data, failingRequest requestID: Int? = nil) throws {
        guard let writer else {
            throw LSPTransportError.processNotRunning
        }
        let frame = Data("Content-Length: \(data.count)\r\n\r\n".utf8) + data
        writer.write(frame) { [weak self] error in
            Task { [weak self] in
                await self?.writeFailed(error, requestID: requestID)
            }
        }
    }

    private func writeFailed(_ error: any Error, requestID: Int?) {
        Self.logger.warning("LSP write failed: \(error.localizedDescription)")
        guard let requestID, let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: error)
    }

    private func runReadLoop(_ chunks: AsyncStream<Data>) async {
        var buffer = Data()
        for await chunk in chunks {
            if Task.isCancelled { return }
            buffer.append(chunk)
            while let (messageData, _) = Self.parseMessageFromBuffer(&buffer) {
                dispatchMessage(messageData)
            }
        }
        if !Task.isCancelled {
            Self.logger.debug("LSP read loop ended at end of output")
        }
    }

    private static func parseMessageFromBuffer(_ buffer: inout Data) -> (Data, Int)? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let separatorRange = buffer.range(of: Data(separator)) else {
            return nil
        }

        let headerData = buffer[buffer.startIndex..<separatorRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        var contentLength: Int?
        for line in headerString.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let valueStr = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(valueStr)
            }
        }

        guard let length = contentLength else {
            return nil
        }

        let bodyStart = separatorRange.upperBound
        let bodyEnd = buffer.index(bodyStart, offsetBy: length, limitedBy: buffer.endIndex)
        guard let end = bodyEnd, end <= buffer.endIndex else {
            return nil
        }

        let body = Data(buffer[bodyStart..<end])
        let totalConsumed = end - buffer.startIndex
        buffer.removeFirst(totalConsumed)
        return (body, totalConsumed)
    }

    private func dispatchMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.logger.warning("Failed to parse JSON-RPC message")
            return
        }

        let id = json["id"] as? Int
        let method = json["method"] as? String

        // Response: has id, no method
        if let id, method == nil {
            if let continuation = pendingRequests.removeValue(forKey: id) {
                if let errorObj = json["error"] as? [String: Any] {
                    let code = errorObj["code"] as? Int ?? -1
                    let message = errorObj["message"] as? String ?? "Unknown error"
                    continuation.resume(throwing: LSPTransportError.serverError(code, message))
                } else {
                    let resultValue = json["result"]
                    if let resultValue, !(resultValue is NSNull),
                       JSONSerialization.isValidJSONObject(resultValue) {
                        do {
                            let resultData = try JSONSerialization.data(withJSONObject: resultValue)
                            continuation.resume(returning: resultData)
                        } catch {
                            continuation.resume(returning: Data("{}".utf8))
                        }
                    } else {
                        continuation.resume(returning: Data("{}".utf8))
                    }
                }
            }
            return
        }

        // Notification or server-initiated request: has method
        if let method {
            if let handler = notificationHandlers[method] {
                handler(data)
            }
            // Server-initiated request (has both id and method) — reply with handler result or null
            if let id {
                if let deferred = deferredRequestHandlers[method] {
                    deferred(data, id)
                    return
                }
                var result: Any = NSNull()
                if let requestHandler = requestHandlers[method] {
                    result = requestHandler(data) ?? NSNull()
                }
                let resultObj: Any = JSONSerialization.isValidJSONObject(result) ? result : NSNull()
                let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": resultObj]
                if let responseData = try? JSONSerialization.data(withJSONObject: response) {
                    try? writeMessage(responseData)
                }
            }
        }
    }

    private func handleProcessExit(code: Int32) {
        Self.logger.info("LSP process exited with code \(code)")
        writer?.close()
        writer = nil
        stdinPipe = nil
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: LSPTransportError.processExited(code))
        }
    }
}
