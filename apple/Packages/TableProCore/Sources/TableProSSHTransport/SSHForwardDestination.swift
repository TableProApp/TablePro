//
//  SSHForwardDestination.swift
//  TableProSSHTransport
//

import Foundation

/// What the SSH server connects to on the far end of a local forward. A TCP destination
/// opens a `direct-tcpip` channel; a socket destination opens a `direct-streamlocal@openssh.com`
/// channel, the equivalent of `ssh -L <localPort>:/path/to/socket`.
public enum SSHForwardDestination: Sendable, Hashable {
    case tcp(host: String, port: Int)
    case unixSocket(path: String)

    public var isUnixSocket: Bool {
        switch self {
        case .tcp: return false
        case .unixSocket: return true
        }
    }

    public var logDescription: String {
        switch self {
        case .tcp(let host, let port): return "\(host):\(port)"
        case .unixSocket(let path): return path
        }
    }
}

/// The `SSH_MSG_CHANNEL_OPEN` request for one forward, as RFC 4254 section 7.2 and OpenSSH's PROTOCOL file lay it out.
public struct SSHForwardChannelRequest: Equatable, Sendable {
    // 94 MiB/s at 200 ms of latency, where libssh2's default of 2 MiB carries 7.4. A channel whose reader stalls
    // while another channel drains the session holds about 1.5 times this in libssh2's queue.
    public static let receiveWindowBytes: UInt32 = 33_554_432
    public static let maximumPacketBytes: UInt32 = 32_768

    public let channelType: String
    public let message: [UInt8]
}

public extension SSHForwardDestination {
    func channelRequest(originHost: String, originPort: Int) -> SSHForwardChannelRequest {
        var message: [UInt8] = []
        switch self {
        case .tcp(let host, let port):
            Self.append(string: host, to: &message)
            Self.append(number: port, to: &message)
            Self.append(string: originHost, to: &message)
            Self.append(number: originPort, to: &message)
            return SSHForwardChannelRequest(channelType: "direct-tcpip", message: message)
        case .unixSocket(let path):
            Self.append(string: path, to: &message)
            Self.append(string: originHost, to: &message)
            Self.append(number: originPort, to: &message)
            return SSHForwardChannelRequest(channelType: "direct-streamlocal@openssh.com", message: message)
        }
    }

    private static func append(string: String, to message: inout [UInt8]) {
        append(number: string.utf8.count, to: &message)
        message.append(contentsOf: string.utf8)
    }

    private static func append(number: Int, to message: inout [UInt8]) {
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: number).bigEndian) { message.append(contentsOf: $0) }
    }
}
