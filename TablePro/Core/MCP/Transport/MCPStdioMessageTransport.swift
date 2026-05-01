import Foundation

public final class MCPStdioMessageTransport: MCPMessageTransport, @unchecked Sendable {
    public let inbound: AsyncThrowingStream<JsonRpcMessage, Error>

    private let continuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation
    private let writer: StdioWriter
    private let errorLogger: MCPBridgeLogger?
    private let stateLock = NSLock()
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    public init(
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput,
        errorLogger: MCPBridgeLogger? = nil
    ) {
        self.errorLogger = errorLogger
        writer = StdioWriter(handle: stdout)

        var capturedContinuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation!
        inbound = AsyncThrowingStream<JsonRpcMessage, Error> { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation

        startReader(stdin: stdin)
    }

    public func send(_ message: JsonRpcMessage) async throws {
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        if closed {
            throw MCPTransportError.closed
        }

        let line: Data
        do {
            line = try JsonRpcCodec.encodeLine(message)
        } catch {
            throw MCPTransportError.writeFailed(detail: String(describing: error))
        }

        do {
            try await writer.write(line)
        } catch {
            throw MCPTransportError.writeFailed(detail: String(describing: error))
        }
    }

    public func close() async {
        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            return
        }
        isClosed = true
        let task = readerTask
        readerTask = nil
        stateLock.unlock()

        task?.cancel()
        continuation.finish()
    }

    private func startReader(stdin: FileHandle) {
        let continuation = continuation
        let logger = errorLogger
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.readLoop(stdin: stdin, continuation: continuation, logger: logger)
            await self?.finishStream()
        }

        stateLock.lock()
        readerTask = task
        stateLock.unlock()
    }

    private func finishStream() async {
        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            return
        }
        isClosed = true
        readerTask = nil
        stateLock.unlock()
        continuation.finish()
    }

    private static func readLoop(
        stdin: FileHandle,
        continuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation,
        logger: MCPBridgeLogger?
    ) async {
        var buffer = Data()
        do {
            for try await byte in stdin.bytes {
                if Task.isCancelled {
                    return
                }
                if byte == 0x0A {
                    processLine(buffer, continuation: continuation, logger: logger)
                    buffer.removeAll(keepingCapacity: true)
                    continue
                }
                buffer.append(byte)
            }
        } catch {
            logger?.log(.error, "stdio read failed: \(error)")
            continuation.finish(throwing: MCPTransportError.readFailed(detail: String(describing: error)))
            return
        }

        if !buffer.isEmpty {
            processLine(buffer, continuation: continuation, logger: logger)
        }
    }

    private static func processLine(
        _ raw: Data,
        continuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation,
        logger: MCPBridgeLogger?
    ) {
        var trimmed = raw
        if trimmed.last == 0x0D {
            trimmed.removeLast()
        }
        if trimmed.isEmpty {
            return
        }

        do {
            let message = try JsonRpcCodec.decode(trimmed)
            continuation.yield(message)
        } catch {
            logger?.log(.warning, "stdio: skipping malformed JSON-RPC line: \(error)")
        }
    }
}

private actor StdioWriter {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        try? handle.synchronize()
    }
}
