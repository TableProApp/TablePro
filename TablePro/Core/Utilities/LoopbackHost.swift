//
//  LoopbackHost.swift
//  TablePro
//

import Foundation

/// Whether a host name reaches this machine and nothing else.
///
/// Several callers each grew their own copy of this, and they disagree: one counts `0.0.0.0` and
/// `localhost.localdomain`, another matches only the four exact spellings and misses the rest of
/// `127.0.0.0/8`. This is the complete one, and the answer any caller deciding whether traffic
/// leaves the machine should ask.
internal enum LoopbackHost {
    private static let names: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    internal static func isLoopback(_ host: String) -> Bool {
        var normalized = host.trimmingCharacters(in: .whitespaces).lowercased()
        while normalized.hasSuffix(".") { normalized.removeLast() }
        if names.contains(normalized) { return true }
        return isLoopbackIPv4(normalized)
    }

    private static func isLoopbackIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard !octet.isEmpty,
                  octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(octet), value <= 255
            else { return false }
        }
        return Int(octets[0]) == 127
    }
}
