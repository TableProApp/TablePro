//
//  SSHTransportSocketOptions.swift
//  TableProSSHTransport
//

import Foundation

public enum SSHTransportSocketOptions {
    public static let idleSeconds: Int32 = 60

    // Returns one line per option the kernel refused, for the caller's log. TCP_NODELAY because every
    // channel of the session shares this socket: Nagle would hold one client's small packet behind
    // another's unacknowledged one, the stall OpenSSH avoids by setting it on interactive sessions.
    public static func enable(on descriptor: Int32) -> [String] {
        var refused: [String] = []
        var enabled: Int32 = 1
        if setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            refused.append("TCP_NODELAY: \(String(cString: strerror(errno)))")
        }
        if setsockopt(descriptor, SOL_SOCKET, SO_KEEPALIVE, &enabled, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            refused.append("SO_KEEPALIVE: \(String(cString: strerror(errno)))")
        }
        var idle = idleSeconds
        if setsockopt(descriptor, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            refused.append("TCP_KEEPALIVE: \(String(cString: strerror(errno)))")
        }
        return refused
    }
}
