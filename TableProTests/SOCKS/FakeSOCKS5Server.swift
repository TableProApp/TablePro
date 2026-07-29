//
//  FakeSOCKS5Server.swift
//  TableProTests
//

import Foundation
import Network
import os

final class FakeSOCKS5Server: @unchecked Sendable {
    enum Behavior: Sendable {
        case echo
        case rejectAuth
        case neverReply
    }

    struct ConnectRequest: Sendable {
        let addressType: UInt8
        let address: Data
        let port: UInt16
    }

    private struct CapturedState {
        var connectRequests: [ConnectRequest] = []
        var sawAuthNegotiation = false
    }

    private let queue = DispatchQueue(label: "com.TablePro.tests.FakeSOCKS5Server")
    private let behavior: Behavior
    private let requiredUsername: String?
    private let requiredPassword: String?
    private let captured = OSAllocatedUnfairLock(initialState: CapturedState())
    private var listener: NWListener?

    private(set) var port: Int = 0

    var capturedConnectRequest: ConnectRequest? {
        captured.withLock { $0.connectRequests.last }
    }

    var sawAuthNegotiation: Bool {
        captured.withLock { $0.sawAuthNegotiation }
    }

    init(behavior: Behavior = .echo, username: String? = nil, password: String? = nil) {
        self.behavior = behavior
        self.requiredUsername = username
        self.requiredPassword = password
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let isTerminal: Bool
                switch state {
                case .failed, .cancelled: isTerminal = true
                default: isTerminal = false
                }
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done, state == .ready || isTerminal else { return false }
                    done = true
                    return true
                }
                guard shouldResume else { return }
                if case .ready = state, let assignedPort = listener.port {
                    continuation.resume(returning: Int(assignedPort.rawValue))
                } else {
                    continuation.resume(throwing: POSIXError(.EADDRINUSE))
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        guard behavior != .neverReply else { return }
        Task {
            do {
                try await self.negotiate(connection)
            } catch {
                connection.cancel()
            }
        }
    }

    private func negotiate(_ connection: NWConnection) async throws {
        let greeting = try await read(connection, count: 2)
        guard greeting[0] == 0x05 else { throw POSIXError(.EPROTO) }
        _ = try await read(connection, count: Int(greeting[1]))

        if requiredUsername != nil || behavior == .rejectAuth {
            try await send(connection, Data([0x05, 0x02]))
            try await performAuthSubnegotiation(connection)
        } else {
            try await send(connection, Data([0x05, 0x00]))
        }

        let request = try await readConnectRequest(connection)
        captured.withLock { $0.connectRequests.append(request) }
        try await send(connection, Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
        echoLoop(connection)
    }

    private func performAuthSubnegotiation(_ connection: NWConnection) async throws {
        let header = try await read(connection, count: 2)
        let username = try await read(connection, count: Int(header[1]))
        let passwordLength = try await read(connection, count: 1)
        let password = try await read(connection, count: Int(passwordLength[0]))
        captured.withLock { $0.sawAuthNegotiation = true }

        let matches = String(data: username, encoding: .utf8) == requiredUsername
            && String(data: password, encoding: .utf8) == requiredPassword
        guard behavior != .rejectAuth, matches else {
            try await send(connection, Data([0x01, 0x01]))
            connection.cancel()
            throw POSIXError(.EAUTH)
        }
        try await send(connection, Data([0x01, 0x00]))
    }

    private func readConnectRequest(_ connection: NWConnection) async throws -> ConnectRequest {
        let header = try await read(connection, count: 4)
        guard header[0] == 0x05, header[1] == 0x01 else { throw POSIXError(.EPROTO) }
        let addressType = header[3]
        let address: Data
        switch addressType {
        case 0x01:
            address = try await read(connection, count: 4)
        case 0x03:
            let length = try await read(connection, count: 1)
            address = try await read(connection, count: Int(length[0]))
        case 0x04:
            address = try await read(connection, count: 16)
        default:
            throw POSIXError(.EPROTO)
        }
        let portBytes = try await read(connection, count: 2)
        let port = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
        return ConnectRequest(addressType: addressType, address: address, port: port)
    }

    private func echoLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete else {
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { sendError in
                    guard sendError == nil else {
                        connection.cancel()
                        return
                    }
                    self.echoLoop(connection)
                })
            } else {
                self.echoLoop(connection)
            }
        }
    }

    private func read(_ connection: NWConnection, count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? NWError.posix(.ECONNRESET))
                }
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
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
}
