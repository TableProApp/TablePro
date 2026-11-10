import Foundation

// Left to the kernel, Darwin sends the first keepalive after 7,200 s of idle, while an AWS Network Load Balancer drops
// an idle flow after 350 s. A session with no query timeout has no read timeout either, so a reply lost with the flow,
// or on a path that died, blocked the statement for hours, and Stop's KILL QUERY could not reach the blocked read.
// These keep the flow open and fail a dead peer about 90 s after the last traffic, the values the PostgreSQL plugin
// gives libpq. A slow statement on a live server still completes: its kernel answers the probes.
public enum MySQLSocketKeepalive {
    public static let idleSeconds: Int32 = 60
    public static let intervalSeconds: Int32 = 10
    public static let probeCount: Int32 = 3

    public static func enable(on socket: Int32) -> Bool {
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
