import Darwin
import Foundation

// An IAM credential is good for whatever endpoint it names, so these answers decide where one may go. A name counts
// as an RDS endpoint only in the shapes RDS publishes, under a partition's own DNS suffix and with a real region.
public enum AWSEndpointHost {
    private static let loopbackNames: Set<String> = ["localhost"]

    public static func normalized(_ host: String) -> String {
        var name = host.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".") {
            name.removeLast()
        }
        return name
    }

    // Decided by the same getaddrinfo call the driver's dial makes, so `127.1` and `::ffff:127.0.0.1` are loopback,
    // while `127.0.0.1.example.com`, `127.0.0.1.`, `127.0.0.1 ` and `[::1]` are names it asks DNS about, which can
    // answer anything. The host is read exactly as the driver gets it.
    public static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased()
        if loopbackNames.contains(name) {
            return true
        }
        switch numericAddress(name) {
        case .ipv4(let address):
            return address >> 24 == 127 || address == 0
        case .ipv6(let bytes):
            let isLoopbackAddress = bytes[0 ..< 15].allSatisfy { $0 == 0 } && bytes[15] == 1
            let mapped = bytes[0 ..< 10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
            return isLoopbackAddress || (mapped && bytes[12] == 127)
        case nil:
            return false
        }
    }

    public static func isRDSEndpoint(_ host: String) -> Bool {
        rdsName(normalized(host)) != nil
    }

    // Nil for a name AWS did not issue, and for a global database endpoint, which names no region.
    public static func rdsRegion(forHost host: String) -> String? {
        rdsName(normalized(host))?.region
    }

    // The RDS endpoint a name of the user's own stands for, found by following its CNAME records. `notFound` when
    // `host` already is one, cannot have one, or leads to none.
    public static func rdsEndpoint(
        behind host: String,
        resolver: any CNAMEResolving,
        within timeout: Duration?
    ) async -> CNAMELookup {
        let name = normalized(host)
        guard isAliasCandidate(name), !isRDSEndpoint(name) else { return .notFound }
        return await resolver.firstName(behind: name, within: timeout, where: isRDSEndpoint)
    }

    // A literal address has no CNAME, a single label is not looked up in DNS, and asking about a `.local` name sends
    // multicast that iOS gates behind the Local Network permission.
    public static func isAliasCandidate(_ host: String) -> Bool {
        let name = normalized(host)
        guard name.contains("."), !name.contains(":"), !name.contains("/"), !name.contains(","),
              !name.hasSuffix(".local")
        else { return false }
        return !isLoopback(name) && numericAddress(name) == nil
    }

    private struct RDSName {
        let region: String?
    }

    private static let dnsSuffixes: [String] = AWSPartition.all.reduce(into: []) { suffixes, partition in
        if !suffixes.contains(partition.dnsSuffix) {
            suffixes.append(partition.dnsSuffix)
        }
    }

    // `<id>.<hash>.<region>.rds.<suffix>` everywhere, `<id>.<hash>.rds.<region>.<suffix>` in China, GovCloud and the
    // ISO partitions, and `<id>.global-<hash>.global.rds.<suffix>` for a global database. A Proxy's own endpoints add
    // labels in front.
    private static func rdsName(_ name: String) -> RDSName? {
        for suffix in dnsSuffixes where name.hasSuffix("." + suffix) {
            let labels = name.dropLast(suffix.count + 1).split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 4, !labels.contains(where: \.isEmpty) else { continue }
            let last = String(labels[labels.count - 1])
            let previous = String(labels[labels.count - 2])
            if last == "rds" {
                if previous == "global" {
                    return RDSName(region: nil)
                }
                if isRegion(previous, under: suffix) {
                    return RDSName(region: previous)
                }
            } else if previous == "rds", isRegion(last, under: suffix) {
                return RDSName(region: last)
            }
        }
        return nil
    }

    // Other services let customers pick labels under the same suffix (`<bucket>.s3.amazonaws.com`), so the label has
    // to read as a region, such as `us-east-1`, `cn-northwest-1` or `us-isob-east-1`.
    private static func isRegion(_ label: String, under suffix: String) -> Bool {
        let parts = label.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let number = parts.last, !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }),
              parts.dropLast().allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "a" && $0 <= "z" } })
        else { return false }
        return AWSPartition.resolve(region: label).dnsSuffix == suffix
    }

    private enum NumericAddress: Equatable {
        case ipv4(UInt32)
        case ipv6([UInt8])
    }

    // AI_NUMERICHOST parses without a lookup. Measured on macOS 27: `127.1`, `0x7f.1` and `2130706433` are
    // 127.0.0.1, and `0177.0.0.1` is 177.0.0.1, not the octal 127.0.0.1 inet_aton reads. It also takes
    // `::1%x,db.example.com` as ::1, while libpq dials each comma-separated host in turn, so only the characters of a
    // bare address are let through.
    private static func numericAddress(_ host: String) -> NumericAddress? {
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == ":" || $0 == "x") }) else {
            return nil
        }
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let list else { return nil }
        defer { freeaddrinfo(list) }
        guard let address = list.pointee.ai_addr else { return nil }
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                .ipv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                .ipv6(withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) })
            }
        default:
            return nil
        }
    }
}
