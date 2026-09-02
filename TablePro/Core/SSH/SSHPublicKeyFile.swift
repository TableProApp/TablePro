//
//  SSHPublicKeyFile.swift
//  TablePro
//

import Foundation
import os

/// One public key in the form both an OpenSSH `.pub` file and the agent protocol carry it: the SSH
/// wire blob, whose leading string names the key type.
internal struct SSHPublicKeyBlob: Hashable, Sendable {
    let keyType: String
    let blob: Data

    /// `pubkey_prepare()` in OpenSSH offers certificates before plain keys.
    var isCertificate: Bool {
        keyType.hasSuffix("-cert-v01@openssh.com")
    }
}

/// Reads the public half of an `IdentityFile` the way OpenSSH does: the named path, then its
/// `.pub` sidecar, then the `-cert.pub` certificate beside it.
///
/// Naming a `.pub` is the documented way to pick one key out of an agent that holds many, and it
/// is the whole point of the directive when the private key lives somewhere TablePro cannot read
/// it, as it does for 1Password and Secretive.
internal enum SSHPublicKeyFile {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHPublicKeyFile")

    /// A `.pub` line is a few hundred bytes. The cap is here because the same path may name a
    /// private key, a directory entry, or something else entirely.
    private static let maximumFileSize = 64 * 1024

    /// Every public key an identity file resolves to, in the order OpenSSH looks for them.
    static func blobs(atIdentityPath path: String) -> [SSHPublicKeyBlob] {
        let expanded = SSHPathUtilities.expandTilde(path)
        guard !expanded.isEmpty else { return [] }

        var seen = Set<Data>()
        var found: [SSHPublicKeyBlob] = []
        for candidate in [expanded, expanded + ".pub", expanded + "-cert.pub"] {
            guard let parsed = parse(contentsOfFileAt: candidate) else { continue }
            guard seen.insert(parsed.blob).inserted else { continue }
            found.append(parsed)
        }
        if found.isEmpty {
            logger.debug("No public key read for identity file: \(expanded, privacy: .private)")
        }
        return found
    }

    /// Parses an OpenSSH public key line, `<type> <base64> [comment]`. A private key file, a
    /// `known_hosts` entry or any other text fails the self-description check and yields nothing.
    static func parse(publicKeyLine line: String) -> SSHPublicKeyBlob? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }

        let keyType = String(fields[0])
        guard let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        guard leadingString(of: blob) == keyType else { return nil }
        return SSHPublicKeyBlob(keyType: keyType, blob: blob)
    }

    private static func parse(contentsOfFileAt path: String) -> SSHPublicKeyBlob? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int,
              size > 0,
              size <= maximumFileSize,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first
        else { return nil }
        return parse(publicKeyLine: String(line))
    }

    /// The first `string` field of an SSH blob: a big-endian length followed by that many bytes.
    private static func leadingString(of blob: Data) -> String? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return nil }

        let length = bytes[0 ..< 4].reduce(Int(0)) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 64, bytes.count >= 4 + length else { return nil }
        return String(bytes: bytes[4 ..< (4 + length)], encoding: .utf8)
    }
}
