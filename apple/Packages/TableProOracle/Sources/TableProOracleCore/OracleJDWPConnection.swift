import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.TablePro", category: "OracleJDWP")

public protocol OracleJDWPTransport: Sendable {
    func send(_ data: Data) async throws
    // Nil once the peer has closed.
    func receive() async throws -> Data?
    func close()
}

public final class OracleJDWPNetworkTransport: OracleJDWPTransport, @unchecked Sendable {
    private let connection: NWConnection

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}

// One JDWP conversation: replies matched to commands by id, everything the VM sends on its own delivered in order.
public actor OracleJDWPConnection {
    private let transport: any OracleJDWPTransport
    private var buffer = OracleJDWPFrameBuffer()
    private var nextID: UInt32 = 1
    private var waiting: [UInt32: CheckedContinuation<Data, Error>] = [:]
    private var timers: [UInt32: Task<Void, Never>] = [:]
    private let replyTimeout: Duration
    private var readTask: Task<Void, Never>?
    private var isClosed = false
    private let commandContinuation: AsyncStream<OracleJDWPPacket>.Continuation
    // Commands the VM sent (Event.Composite), raw: the first can arrive before ID sizes are known.
    nonisolated public let commands: AsyncStream<OracleJDWPPacket>

    // Every command Oracle answers is a lookup; a peer that takes this long has stopped answering.
    public static let defaultReplyTimeout: Duration = .seconds(15)

    public init(transport: any OracleJDWPTransport, replyTimeout: Duration = OracleJDWPConnection.defaultReplyTimeout) {
        self.transport = transport
        self.replyTimeout = replyTimeout
        (commands, commandContinuation) = AsyncStream.makeStream(of: OracleJDWPPacket.self)
    }

    // The JDWP spec has the debugger send first; Oracle sends its 14 bytes first (measured), so either order works.
    public func handshake() async throws {
        try await transport.send(OracleJDWPPacket.handshake)
        while true {
            if let head = buffer.take(OracleJDWPPacket.handshake.count) {
                guard head == OracleJDWPPacket.handshake else { throw OracleJDWPError.handshakeFailed }
                break
            }
            guard let data = try await transport.receive() else { throw OracleJDWPError.handshakeFailed }
            buffer.append(data)
        }
        startReading()
    }

    private func startReading() {
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    private func readLoop() async {
        do {
            while true {
                try deliverBufferedPackets()
                guard let data = try await transport.receive() else { break }
                buffer.append(data)
            }
        } catch {
            logger.notice("JDWP read ended: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)")
        }
        finish()
    }

    private func deliverBufferedPackets() throws {
        while let packet = try buffer.nextPacket() {
            switch packet {
            case let .reply(id, errorCode, data):
                timers.removeValue(forKey: id)?.cancel()
                guard let continuation = waiting.removeValue(forKey: id) else { continue }
                if errorCode == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: OracleJDWPError.reply(code: Int(errorCode)))
                }
            case .command:
                commandContinuation.yield(packet)
            }
        }
    }

    // A reply that does not come within the timeout, or a caller that is cancelled, closes the connection: closing is
    // what ends the target, and it fails every other reply still awaited.
    public func send(_ commandSet: UInt8, _ command: UInt8, _ data: Data = Data()) async throws -> Data {
        guard !isClosed else { throw OracleJDWPError.closed }
        let id = nextID
        nextID &+= 1
        let packet = OracleJDWPPacket.command(id: id, commandSet: commandSet, command: command, data: data)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiting[id] = continuation
                    timers[id] = Task { [weak self, replyTimeout] in
                        guard (try? await Task.sleep(for: replyTimeout)) != nil else { return }
                        await self?.expire(id: id)
                    }
                    Task {
                        do {
                            try await self.transport.send(packet.encoded)
                        } catch {
                            self.fail(id: id, error: error)
                        }
                    }
                }
            } onCancel: {
                Task { await self.close() }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func fail(id: UInt32, error: Error) {
        timers.removeValue(forKey: id)?.cancel()
        waiting.removeValue(forKey: id)?.resume(throwing: OracleJDWPError.closed)
    }

    private func expire(id: UInt32) {
        timers.removeValue(forKey: id)
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        logger.error("The JDWP peer did not answer a command in time; closing the connection")
        continuation.resume(throwing: OracleJDWPError.timedOut)
        close()
    }

    // Closing without VirtualMachine.Dispose ends the target session (ORA-30687, measured), which is what Stop needs.
    public func close() {
        transport.close()
        finish()
    }

    // A frame that fails to decode ends here too, and the socket closes with it so the target ends.
    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        transport.close()
        for timer in timers.values {
            timer.cancel()
        }
        timers.removeAll()
        let pending = waiting
        waiting.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: OracleJDWPError.closed)
        }
        commandContinuation.finish()
        readTask?.cancel()
    }

    public var closed: Bool { isClosed }
}
