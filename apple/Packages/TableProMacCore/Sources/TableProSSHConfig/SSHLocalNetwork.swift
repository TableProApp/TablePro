//
//  SSHLocalNetwork.swift
//  TablePro
//

import Darwin
import Foundation

// `Match localnetwork`: true when an address of an interface that is up falls in one of the
// comma-separated CIDR networks, as ssh's `check_match_ifaddrs` does.
enum SSHLocalNetwork {
    static func contains(anyOf addresses: [String], in networks: String) -> Bool {
        let cidrs = networks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return addresses.contains { address in
            cidrs.contains { contains(address: address, cidr: $0) }
        }
    }

    static func contains(address: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
        guard let network = parts.first.flatMap(bytes(of:)),
              let candidate = bytes(of: address),
              network.count == candidate.count
        else { return false }
        let width = network.count * 8
        guard let prefix = parts.count == 2 ? Int(parts[1]) : width, (0...width).contains(prefix) else { return false }

        for bit in 0..<prefix {
            let mask = UInt8(0x80) >> UInt8(bit % 8)
            if network[bit / 8] & mask != candidate[bit / 8] & mask { return false }
        }
        return true
    }

    static func interfaceAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [String] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard Int32(interface.pointee.ifa_flags) & IFF_UP != 0,
                  let address = interface.pointee.ifa_addr
            else { continue }
            let family = Int32(address.pointee.sa_family)
            let length: Int
            switch family {
            case AF_INET: length = MemoryLayout<sockaddr_in>.size
            case AF_INET6: length = MemoryLayout<sockaddr_in6>.size
            default: continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(length), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            addresses.append(String(cString: host))
        }
        return addresses
    }

    private static func bytes(of address: String) -> [UInt8]? {
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }
}
