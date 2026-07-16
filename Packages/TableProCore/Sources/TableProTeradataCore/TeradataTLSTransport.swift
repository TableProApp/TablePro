import Foundation
import Network
import Security

final class TeradataTLSTransport: TeradataTransport {
    private let connection: NWConnection
    private let condition = NSCondition()
    private let timeoutSeconds: Int
    private var buffer: [UInt8] = []
    private var receiveError: Error?
    private var peerClosed = false
    private var cancelled = false

    init(host: String, port: UInt16, options: TeradataTLSOptions, timeoutSeconds: Int) throws {
        self.timeoutSeconds = timeoutSeconds
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw TeradataWireError.connectionFailed("invalid port \(port)")
        }
        let queue = DispatchQueue(label: "com.TablePro.teradata.tls")

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
                    SecTrustSetAnchorCertificatesOnly(trust, false)
                }
                complete(SecTrustEvaluateWithError(trust, nil))
            },
            queue)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        if ready.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            connection.cancel()
            throw TeradataWireError.connectionFailed("TLS handshake to \(host):\(port) timed out")
        }
        if let failure {
            connection.cancel()
            throw TeradataWireError.connectionFailed("TLS handshake failed: \(failure)")
        }
        startReceiveLoop()
    }

    func send(_ bytes: [UInt8]) throws {
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

    func receive(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while buffer.count < count {
            if cancelled { throw TeradataWireError.cancelled }
            if let receiveError { throw TeradataWireError.truncated("TLS recv: \(receiveError)") }
            if peerClosed { throw TeradataWireError.truncated("TLS peer closed after \(buffer.count)/\(count)") }
            if !condition.wait(until: deadline) { throw TeradataWireError.truncated("TLS recv timed out") }
        }
        let result = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    func cancel() {
        stop()
    }

    func close() {
        stop()
    }

    private func stop() {
        condition.lock()
        cancelled = true
        condition.signal()
        condition.unlock()
        connection.cancel()
    }

    private func startReceiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.condition.lock()
            if let data, !data.isEmpty { self.buffer.append(contentsOf: data) }
            if let error { self.receiveError = error }
            if isComplete { self.peerClosed = true }
            let shouldContinue = error == nil && !isComplete && !self.cancelled
            self.condition.signal()
            self.condition.unlock()
            if shouldContinue { self.startReceiveLoop() }
        }
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
