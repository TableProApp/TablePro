import Foundation

// Left to the kernel, Darwin sends the first keepalive after 7,200 s of idle, while an AWS Network Load Balancer drops
// an idle flow after 350 s, so a reply lost with the flow, or on a path that died, blocked a session waiting on it for
// hours. These keep the flow open and fail a dead peer about 90 s after the last traffic, the values the Mac's
// PostgreSQL connection uses. A slow statement on a live server still completes: its kernel answers the probes.
nonisolated enum SessionSocketKeepalive {
    static let idleSeconds: Int32 = 60
    static let intervalSeconds: Int32 = 10
    static let probeCount: Int32 = 3

    // libpq applies the interval and count while it connects; the iOS build drops the idle time, which the driver sets
    // with `enable` once the connect completes.
    static let libpqParameters: [(String, String)] = [
        ("keepalives", "1"),
        ("keepalives_idle", String(idleSeconds)),
        ("keepalives_interval", String(intervalSeconds)),
        ("keepalives_count", String(probeCount)),
    ]

    static func enable(on socket: Int32) -> Bool {
        set(socket, SOL_SOCKET, SO_KEEPALIVE, 1)
            && set(socket, IPPROTO_TCP, TCP_KEEPALIVE, idleSeconds)
            && set(socket, IPPROTO_TCP, TCP_KEEPINTVL, intervalSeconds)
            && set(socket, IPPROTO_TCP, TCP_KEEPCNT, probeCount)
    }

    private static func set(_ socket: Int32, _ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
        var value = value
        return setsockopt(socket, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0
    }
}
