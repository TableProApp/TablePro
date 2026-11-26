import Darwin
import Foundation
import os

import TableProSSHTransport

extension LibSSH2TunnelFactory {
    // Resolves off the cooperative pool as before, then races the addresses (RFC 8305) on the attempt's own
    // queue. The attempt's interrupt wakes the race, and the deadline bounds the whole of it.
    internal static func connectTCP(
        host: String,
        port: Int,
        deadline: ConnectionDeadline,
        attempt: SSHConnectionAttempt
    ) async throws -> Int32 {
        let endpoint = timeoutEndpoint(host: host, port: port)
        try attempt.prepare(for: endpoint)
        let addresses = try await resolveAddresses(
            host: host,
            port: port,
            deadline: deadline,
            attempt: attempt,
            endpoint: endpoint
        )
        try attempt.prepare(for: endpoint)

        let interrupt = SSHDialInterrupt()
        let interruptId = attempt.registerTransportInterrupt { interrupt.fire() }
        let outcome = try await attempt.runBlocking {
            SSHTransportDial.connect(addresses, deadline: deadline.instant, interrupt: interrupt)
        }
        attempt.unregisterTransportInterrupt(interruptId)

        switch outcome {
        case .connected(let descriptor):
            configureTransportSocket(descriptor)
            do {
                try attempt.check(for: endpoint)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            logger.debug("TCP connected to \(host):\(port)")
            return descriptor
        case .interrupted:
            try attempt.check(for: endpoint)
            throw CancellationError()
        case .timedOut:
            try attempt.check(for: endpoint)
            throw deadline.timeoutError(for: endpoint)
        case .failed(let lastErrno):
            try attempt.check(for: endpoint)
            let reason = lastErrno.map {
                "Connection to \(host):\(port) failed: \(String(cString: strerror($0)))"
            } ?? "No address found"
            throw SSHTunnelError.tunnelCreationFailed(reason)
        }
    }

    private static func resolveAddresses(
        host: String,
        port: Int,
        deadline: ConnectionDeadline,
        attempt: SSHConnectionAttempt,
        endpoint: ConnectionTimeoutEndpoint
    ) async throws -> [SSHSocketAddress] {
        let gate = ConnectionSingleResumeGate<[SSHSocketAddress]>()
        let queue = DispatchQueue.global(qos: .utility)
        let remainingMilliseconds = max(1, deadline.remainingMilliseconds)

        queue.asyncAfter(deadline: .now() + .milliseconds(remainingMilliseconds)) {
            gate.resume(with: .failure(deadline.timeoutError(for: endpoint)))
        }
        queue.async {
            let result = resolvedAddresses(host: host, port: port)
            gate.resume(with: result)
        }

        return try await withTaskCancellationHandler {
            let addresses = try await gate.wait()
            try attempt.check(for: endpoint)
            return addresses
        } onCancel: {
            attempt.cancel()
            gate.resume(with: .failure(CancellationError()))
        }
    }

    private static func resolvedAddresses(
        host: String,
        port: Int
    ) -> Result<[SSHSocketAddress], Error> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let resultCode = getaddrinfo(host, String(port), &hints, &result)
        guard resultCode == 0, let firstAddress = result else {
            let message = resultCode == 0 ? "No address found" : String(cString: gai_strerror(resultCode))
            return .failure(
                SSHTunnelError.tunnelCreationFailed("DNS resolution failed for \(host): \(message)")
            )
        }
        defer { freeaddrinfo(result) }

        let addresses = SSHSocketAddress.list(from: firstAddress)
        guard !addresses.isEmpty else {
            return .failure(
                SSHTunnelError.tunnelCreationFailed("DNS resolution failed for \(host): No address found")
            )
        }
        return .success(addresses)
    }

    private static func configureTransportSocket(_ descriptor: Int32) {
        for refusal in SSHTransportSocketOptions.enable(on: descriptor) {
            logger.warning("Failed to set \(refusal, privacy: .public)")
        }
    }
}
