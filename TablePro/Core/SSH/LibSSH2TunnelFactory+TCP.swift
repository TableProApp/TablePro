import Darwin
import Foundation
import os

extension LibSSH2TunnelFactory {
    private struct ResolvedSocketAddress: @unchecked Sendable {
        let storage: sockaddr_storage
        let length: socklen_t
        let family: Int32
        let socketType: Int32
        let socketProtocol: Int32
    }

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
        var lastError = "No address found"

        for address in addresses {
            try attempt.prepare(for: endpoint)
            let descriptor = socket(address.family, address.socketType, address.socketProtocol)
            guard descriptor >= 0 else { continue }

            let interruptId = attempt.registerTransportInterrupt {
                shutdown(descriptor, SHUT_RDWR)
            }
            let flags = fcntl(descriptor, F_GETFL, 0)
            fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

            var storage = address.storage
            let connectResult = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, address.length)
                }
            }

            if connectResult != 0, errno != EINPROGRESS {
                attempt.unregisterTransportInterrupt(interruptId)
                Darwin.close(descriptor)
                lastError = "Connection to \(host):\(port) failed"
                continue
            }

            if connectResult != 0 {
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let pollResult = poll(
                    &pollDescriptor,
                    1,
                    Int32(clamping: deadline.remainingMilliseconds)
                )

                if pollResult <= 0 {
                    attempt.unregisterTransportInterrupt(interruptId)
                    Darwin.close(descriptor)
                    try attempt.check(for: endpoint)
                    if pollResult == 0 {
                        throw deadline.timeoutError(for: endpoint)
                    }
                    lastError = "Connection to \(host):\(port) failed: \(String(cString: strerror(errno)))"
                    continue
                }

                var socketError: Int32 = 0
                var errorLength = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &errorLength)

                if socketError != 0 {
                    attempt.unregisterTransportInterrupt(interruptId)
                    Darwin.close(descriptor)
                    lastError = "Connection to \(host):\(port) failed: \(String(cString: strerror(socketError)))"
                    continue
                }
            }

            fcntl(descriptor, F_SETFL, flags)
            configureKeepAlive(descriptor)

            do {
                try attempt.check(for: endpoint)
            } catch {
                attempt.unregisterTransportInterrupt(interruptId)
                Darwin.close(descriptor)
                throw error
            }
            logger.debug("TCP connected to \(host):\(port)")
            return descriptor
        }

        throw SSHTunnelError.tunnelCreationFailed(lastError)
    }

    private static func resolveAddresses(
        host: String,
        port: Int,
        deadline: ConnectionDeadline,
        attempt: SSHConnectionAttempt,
        endpoint: ConnectionTimeoutEndpoint
    ) async throws -> [ResolvedSocketAddress] {
        let gate = ConnectionSingleResumeGate<[ResolvedSocketAddress]>()
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
    ) -> Result<[ResolvedSocketAddress], Error> {
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

        let addresses = copyAddresses(from: firstAddress)
        guard !addresses.isEmpty else {
            return .failure(
                SSHTunnelError.tunnelCreationFailed("DNS resolution failed for \(host): No address found")
            )
        }
        return .success(addresses)
    }

    private static func copyAddresses(
        from firstAddress: UnsafeMutablePointer<addrinfo>
    ) -> [ResolvedSocketAddress] {
        var addresses: [ResolvedSocketAddress] = []
        var currentAddress: UnsafeMutablePointer<addrinfo>? = firstAddress
        while let address = currentAddress {
            if let source = address.pointee.ai_addr {
                var storage = sockaddr_storage()
                let byteCount = min(Int(address.pointee.ai_addrlen), MemoryLayout<sockaddr_storage>.size)
                withUnsafeMutableBytes(of: &storage) { destination in
                    destination.copyBytes(from: UnsafeRawBufferPointer(start: source, count: byteCount))
                }
                addresses.append(ResolvedSocketAddress(
                    storage: storage,
                    length: address.pointee.ai_addrlen,
                    family: address.pointee.ai_family,
                    socketType: address.pointee.ai_socktype,
                    socketProtocol: address.pointee.ai_protocol
                ))
            }
            currentAddress = address.pointee.ai_next
        }
        return addresses
    }

    private static func configureKeepAlive(_ descriptor: Int32) {
        var enabled: Int32 = 1
        if setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_KEEPALIVE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) != 0 {
            logger.warning("Failed to set SO_KEEPALIVE: \(String(cString: strerror(errno)))")
        }

        var idleSeconds: Int32 = 60
        if setsockopt(
            descriptor,
            IPPROTO_TCP,
            TCP_KEEPALIVE,
            &idleSeconds,
            socklen_t(MemoryLayout<Int32>.size)
        ) != 0 {
            logger.warning("Failed to set TCP_KEEPALIVE: \(String(cString: strerror(errno)))")
        }
    }
}
