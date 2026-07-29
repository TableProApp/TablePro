import Foundation
import Network
import Security

final class TeradataTLSTransport: TeradataTransport {
    private let connection: NWConnection
    private let condition = NSCondition()
    private let timeoutSeconds: Int
    private var rawBuffer: [UInt8] = []
    private var messageBuffer: [UInt8] = []
    private var receiveError: Error?
    private var peerClosed = false
    private var cancelled = false
    private var handshakeComplete = false

    init(host: String, options: TeradataTLSOptions, timeoutSeconds: Int) throws {
        self.timeoutSeconds = timeoutSeconds
        guard let endpointPort = NWEndpoint.Port(rawValue: options.httpsPort) else {
            throw TeradataWireError.connectionFailed("invalid TLS port \(options.httpsPort)")
        }
        let queue = DispatchQueue(label: "com.TablePro.teradata.tls")
        let verifyQueue = DispatchQueue(label: "com.TablePro.teradata.tls.verify")

        let tlsOptions = NWProtocolTLS.Options()
        let anchors = Self.loadAnchors(options.caCertificatePath)
        let verifiesCertificate = options.verifiesCertificate
        let verifiesHostname = options.verifiesHostname
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, trustRef, complete in
                guard verifiesCertificate else { complete(true); return }
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                let policy = SecPolicyCreateSSL(true, verifiesHostname ? (host as CFString) : nil)
                SecTrustSetPolicies(trust, policy)
                if let anchors, !anchors.isEmpty {
                    SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                    SecTrustSetAnchorCertificatesOnly(trust, true)
                }
                complete(SecTrustEvaluateWithError(trust, nil))
            },
            verifyQueue)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            case .cancelled: ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        if ready.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            connection.cancel()
            throw TeradataWireError.connectionFailed("TLS handshake to \(host):\(options.httpsPort) timed out")
        }
        if let failure {
            connection.cancel()
            throw TeradataWireError.connectionFailed("TLS handshake failed: \(failure)")
        }
        startReceiveLoop()
        try performWebSocketHandshake(host: host, path: options.webSocketPath)
        handshakeComplete = true
    }

    func send(_ bytes: [UInt8]) throws {
        try sendRaw(WebSocketFrame.encodeBinary(bytes))
    }

    func receive(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while messageBuffer.count < count {
            try drainFramesLocked()
            if messageBuffer.count >= count { break }
            if cancelled { throw TeradataWireError.cancelled }
            if let receiveError { throw TeradataWireError.truncated("TLS recv: \(receiveError)") }
            if peerClosed { throw TeradataWireError.truncated("WebSocket closed after \(messageBuffer.count)/\(count)") }
            if !condition.wait(until: deadline) { throw TeradataWireError.truncated("TLS recv timed out") }
        }
        let result = Array(messageBuffer.prefix(count))
        messageBuffer.removeFirst(count)
        return result
    }

    func cancel() { stop() }
    func close() { stop() }

    private func stop() {
        condition.lock()
        cancelled = true
        condition.signal()
        condition.unlock()
        connection.cancel()
    }

    private func performWebSocketHandshake(host: String, path: String) throws {
        let keyBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        let request = "GET \(path) HTTP/1.1\r\n"
            + "Host: \(host)\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        try sendRaw(Array(request.utf8))

        let header = try readRawUntilHeaderEnd()
        let response = String(decoding: header, as: UTF8.self)
        guard response.contains(" 101 ") else {
            throw TeradataWireError.connectionFailed("WebSocket upgrade rejected: \(response.split(separator: "\r\n").first ?? "")")
        }
        let expected = WebSocketFrame.acceptKey(for: key)
        guard response.lowercased().contains("sec-websocket-accept: \(expected.lowercased())") else {
            throw TeradataWireError.connectionFailed("WebSocket accept mismatch")
        }
    }

    private func readRawUntilHeaderEnd() throws -> [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        while true {
            if let range = Self.range(of: terminator, in: rawBuffer) {
                let end = range.upperBound
                let header = Array(rawBuffer[..<end])
                rawBuffer.removeFirst(end)
                return header
            }
            if cancelled { throw TeradataWireError.cancelled }
            if let receiveError { throw TeradataWireError.truncated("WebSocket handshake recv: \(receiveError)") }
            if peerClosed { throw TeradataWireError.truncated("WebSocket handshake closed early") }
            if !condition.wait(until: deadline) { throw TeradataWireError.truncated("WebSocket handshake timed out") }
        }
    }

    private func drainFramesLocked() throws {
        while let frame = try WebSocketFrame.decode(&rawBuffer) {
            switch frame.opcode {
            case .binary, .continuation:
                messageBuffer.append(contentsOf: frame.payload)
            case .ping:
                sendPong(frame.payload)
            case .close:
                peerClosed = true
            case .pong:
                break
            }
        }
    }

    private func sendPong(_ payload: [UInt8]) {
        connection.send(
            content: Data(WebSocketFrame.encode(opcode: .pong, payload: payload)),
            completion: .idempotent)
    }

    private func sendRaw(_ bytes: [UInt8]) throws {
        condition.lock()
        let stopped = cancelled
        condition.unlock()
        if stopped { throw TeradataWireError.cancelled }

        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            sendError = error
            semaphore.signal()
        })
        if semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            throw TeradataWireError.truncated("TLS send timed out")
        }
        if let sendError { throw TeradataWireError.truncated("TLS send: \(sendError)") }
    }

    private func startReceiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.condition.lock()
            if let data, !data.isEmpty { self.rawBuffer.append(contentsOf: data) }
            if let error { self.receiveError = error }
            if isComplete { self.peerClosed = true }
            let shouldContinue = error == nil && !isComplete && !self.cancelled
            self.condition.signal()
            self.condition.unlock()
            if shouldContinue { self.startReceiveLoop() }
        }
    }

    private static func range(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return start..<(start + needle.count)
        }
        return nil
    }

    private static func loadAnchors(_ path: String) -> [SecCertificate]? {
        guard !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        if let certificate = SecCertificateCreateWithData(nil, data as CFData) { return [certificate] }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var certificates: [SecCertificate] = []
        var encoded = ""
        var inCertificate = false
        for line in text.components(separatedBy: .newlines) {
            if line.contains("BEGIN CERTIFICATE") { inCertificate = true; encoded = ""; continue }
            if line.contains("END CERTIFICATE") {
                inCertificate = false
                if let der = Data(base64Encoded: encoded),
                   let certificate = SecCertificateCreateWithData(nil, der as CFData) {
                    certificates.append(certificate)
                }
                continue
            }
            if inCertificate { encoded += line.trimmingCharacters(in: .whitespaces) }
        }
        return certificates.isEmpty ? nil : certificates
    }
}
