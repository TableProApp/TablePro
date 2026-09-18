//
//  SFTPTestServer.swift
//  TableProTests
//

import Foundation

@testable import TablePro

/// Locates the OpenSSH server that `scripts/sftp-test-server.sh up` starts.
///
/// The gate is a reachability probe rather than an environment variable, for the reason
/// `KafkaTestBroker` records: `xcodebuild` does not pass the invoking shell's environment to the
/// test host, so exporting a variable before a test run arrives as nothing and the suite reports
/// zero executed cases while a server sits there answering.
enum SFTPTestServer {
    static let host = "127.0.0.1"
    static let port = 22_022
    static let username = "tp"
    static let password = "tppass"

    /// The login directory of the container's account. Every test path hangs off this.
    static let homeDirectory = "/config"

    static let isConfigured: Bool = canReach()

    static var configuration: SSHConfiguration {
        var config = SSHConfiguration()
        config.enabled = true
        config.host = host
        config.port = port
        config.username = username
        config.authMethod = .password
        return config
    }

    static var credentials: SSHTunnelCredentials {
        SSHTunnelCredentials(
            sshPassword: password,
            keyPassphrase: nil,
            totpSecret: nil,
            keyboardInteractivePromptProvider: nil
        )
    }

    static func openSession(label: String = "test") async throws -> LibSSH2SFTPSession {
        try await LibSSH2SFTPSession.open(
            config: configuration,
            credentials: credentials,
            label: label
        )
    }

    /// Writes random bytes on the server and returns the SHA-256 **the server itself computed**.
    ///
    /// Seeding this way rather than by uploading keeps the check honest: the expected digest comes
    /// from the far side, so a download that agrees with it agrees with something this code did not
    /// produce. A test that uploaded its own bytes and then compared them to what came back would
    /// pass even if both directions shared a defect.
    static func seedRemoteFile(
        session: LibSSH2SFTPSession,
        at path: String,
        bytes: Int
    ) throws -> String {
        let quoted = LibSSH2ExecChannel.shellQuoted(path)
        let create = try session.runRemoteCommand(
            "dd if=/dev/urandom of=\(quoted) bs=1 count=0 seek=0 2>/dev/null; "
                + "head -c \(bytes) /dev/urandom > \(quoted)"
        )
        guard create.succeeded else {
            throw SFTPError.remoteCommandFailed(
                command: "seed", status: create.exitStatus, output: create.standardError
            )
        }

        let digest = try session.runRemoteCommand("sha256sum \(quoted) 2>/dev/null || shasum -a 256 \(quoted)")
        guard digest.succeeded, let first = digest.trimmedOutput.split(separator: " ").first else {
            throw SFTPError.remoteCommandFailed(
                command: "sha256sum", status: digest.exitStatus, output: digest.standardError
            )
        }
        return String(first)
    }

    /// A unique path under the account's home, so concurrent cases never collide.
    static func scratchPath(_ name: String) -> String {
        "\(homeDirectory)/tablepro-test-\(UUID().uuidString)-\(name)"
    }

    private static func canReach() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return connected
    }
}
