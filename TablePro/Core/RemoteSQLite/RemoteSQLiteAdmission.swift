//
//  RemoteSQLiteAdmission.swift
//  TablePro
//

import Foundation

/// Validates the line a client sends before any protocol frame, so only the driver the transport
/// handed the token to can reach the server's database through the loopback listener.
///
/// Unlike a forwarded database port, whose database still authenticates the client, this listener
/// stands in front of a session that runs SQL with no further credential. The token is per
/// connection and random, and the comparison is constant time so a local process cannot recover it
/// one byte at a time.
enum RemoteSQLiteAdmission {
    static let maxLineLength = 256

    static func isAuthorized(line: Data, token: String) -> Bool {
        guard !token.isEmpty, line.count <= maxLineLength else { return false }
        guard let text = String(data: line, encoding: .utf8), text.hasPrefix(RemoteSQLiteWire.admissionPrefix) else {
            return false
        }
        let presented = String(text.dropFirst(RemoteSQLiteWire.admissionPrefix.count))
        return constantTimeEquals(presented, token)
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<left.count {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            /// The system RNG effectively never fails on macOS, but an all-zero token on the one
            /// path that would produce it is a guessable admission secret, so fall back to two
            /// UUIDs rather than ship zeros.
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
