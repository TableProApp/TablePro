//
//  LSPTransport.swift
//  TablePro
//

import Foundation
import os

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

// MARK: - LSPTransport

actor LSPTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LSPTransport")

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var nextRequestID: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var notificationHandlers: [String: @Sendable (Data) -> Void] = [:]
    private var requestHandlers: [String: @Sendable (Data) -> Any?] = [:]
    private var deferredRequestHandlers: [String: @Sendable (Data, Int) -> Void] = [:]
    private var readerQueue: DispatchQueue?

    // MARK: - Lifecycle

    func start(executablePath: String, arguments: [String] = [], environment: [String: String]? = nil) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments

        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            proc.environment = env
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

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

        // Drain stderr to prevent pipe buffer from filling
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                Self.logger.debug("LSP stderr: \(text)")
            }
        }

        try proc.run()

        let queue = DispatchQueue(label: "com.TablePro.LSPTransport.reader")
        self.readerQueue = queue
        let handle = stdout.fileHandleForReading
        queue.async { [weak self] in
            self?.readLoopSync(handle: handle)
        }

        Self.logger.info("LSP transport started: \(executablePath)")
    }

    func stop() {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: LSPTransportError.requestCancelled)
        }

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        readerQueue = nil

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
                try writeMessage(data)
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
        if let data = try? JSONEncoder().encode(LSPJSONRPCNotification(method: "$/cancelRequest", params: params)) {
            try? writeMessage(data)
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

    private func writeMessage(_ data: Data) throws {
        guard let stdinPipe else {
            throw LSPTransportError.processNotRunning
        }

        let header = "Content-Length: \(data.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else {
            throw LSPTransportError.invalidResponse
        }

        let handle = stdinPipe.fileHandleForWriting
        handle.write(headerData)
        handle.write(data)
    }

    /// Blocking read loop that runs on a dedicated DispatchQueue to avoid blocking the actor executor.
    nonisolated private func readLoopSync(handle: FileHandle) {
        var buffer = Data()

        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break } // EOF
            buffer.append(chunk)

            while let (messageData, _) = Self.parseMessageFromBuffer(&buffer) {
                let data = messageData
                Task { [weak self] in await self?.dispatchMessage(data) }
            }
        }
    }

    /// Parse a single LSP message from the buffer.
    /// Returns (messageBody, totalBytesConsumed) or nil if buffer is incomplete.
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
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: LSPTransportError.processExited(code))
        }
    }
}
