import Darwin
import Foundation

public enum OracleDebugNetwork {
    // The address this Mac sends from to reach the database: a connected UDP socket picks the route and sends nothing.
    // It is where a server on the same network can reach back; a NAT, VPN or container can still need another.
    public static func localAddress(towardHost host: String, port: Int) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: resolveLocalAddress(towardHost: host, port: port))
            }
        }
    }

    // One spelling per address: no IPv6 zone, an IPv4-mapped IPv6 address as IPv4, lowercase hex.
    public static func normalized(_ address: String) -> String {
        var text = address.lowercased()
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if text.hasPrefix("::ffff:"), text.dropFirst(7).contains(".") { text = String(text.dropFirst(7)) }
        return text
    }

    // Every address `host` resolves to, numeric and normalized.
    public static func resolvedAddresses(of host: String) async -> Set<String> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: resolve(host))
            }
        }
    }

    static func resolve(_ host: String) -> Set<String> {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var list: UnsafeMutablePointer<addrinfo>?
        guard !host.isEmpty, getaddrinfo(host, nil, &hints, &list) == 0, let list else { return [] }
        defer { freeaddrinfo(list) }
        var addresses: Set<String> = []
        var entry: UnsafeMutablePointer<addrinfo>? = list
        while let current = entry {
            if let address = numericHost(current.pointee.ai_addr, length: current.pointee.ai_addrlen) {
                addresses.insert(normalized(address))
            }
            entry = current.pointee.ai_next
        }
        return addresses
    }

    public static func localInterfaceAddresses() -> Set<String> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: Set<String> = []
        var entry: UnsafeMutablePointer<ifaddrs>? = list
        while let current = entry {
            if let address = current.pointee.ifa_addr {
                let family = Int32(address.pointee.sa_family)
                if family == AF_INET || family == AF_INET6,
                   let text = numericHost(address, length: socklen_t(address.pointee.sa_len)) {
                    addresses.insert(normalized(text))
                }
            }
            entry = current.pointee.ifa_next
        }
        return addresses
    }

    // The local addresses the listener binds: the Debugger Host when it names this Mac, else the address this Mac
    // reaches the database from, which is where a server on that network connects back to. A loopback route binds
    // 127.0.0.1: `localhost` resolves to ::1 first, but Docker Desktop delivers a container's connection on
    // 127.0.0.1 (measured), and Network.framework refuses ::1 on a port 127.0.0.1 holds (EADDRINUSE, measured), so
    // the two cannot share the one port CONNECT_TCP is given. Nil listens everywhere.
    public static func bindAddresses(debuggerHost: String, databaseHost: String, databasePort: Int) async -> [String]? {
        let local = localInterfaceAddresses()
        let named = await resolvedAddresses(of: debuggerHost).filter { local.contains($0) }
        if named.contains("127.0.0.1") {
            return ["127.0.0.1"]
        }
        if let match = named.min() {
            return [match]
        }
        guard let route = await localAddress(towardHost: databaseHost, port: databasePort).map(normalized) else { return nil }
        return isLoopback(route) ? ["127.0.0.1"] : [route]
    }

    public static func isLoopback(_ address: String) -> Bool {
        let text = normalized(address)
        return text == "::1" || text.hasPrefix("127.")
    }

    static func numericHost(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func resolveLocalAddress(towardHost host: String, port: Int) -> String? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_family = AF_UNSPEC
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else { return nil }
        defer { freeaddrinfo(list) }
        var entry: UnsafeMutablePointer<addrinfo>? = list
        while let current = entry {
            defer { entry = current.pointee.ai_next }
            let socketDescriptor = socket(current.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
            guard socketDescriptor >= 0 else { continue }
            defer { close(socketDescriptor) }
            guard connect(socketDescriptor, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 else { continue }
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let named = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketDescriptor, $0, &length) }
            }
            guard named == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let printed = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                }
            }
            guard printed == 0 else { continue }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            guard let address = String(bytes: bytes, encoding: .utf8) else { continue }
            // An IPv6 link-local address carries its interface after `%`, which the server has no use for.
            return address.split(separator: "%").first.map(String.init) ?? address
        }
        return nil
    }
}
