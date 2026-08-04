//
//  SocketPair.swift
//  TableProTests
//
//  Closing is tracked per descriptor because the suite runs in parallel: closing an
//  already-closed fd releases a number the kernel may have handed to a socket another
//  test is still polling, which makes that test observe a hangup it never caused.
//

import Foundation

/// A connected pair of local socket fds, used to drive relay and channel-open tests over
/// real sockets rather than fakes, so closing behaviour is observed the way a database
/// client would observe it.
internal final class SocketPair {
    private(set) var a: Int32
    private(set) var b: Int32

    init() {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            a = -1
            b = -1
            return
        }
        a = fds[0]
        b = fds[1]
    }

    func closeB() { Self.close(&b) }

    func close() {
        Self.close(&a)
        Self.close(&b)
    }

    private static func close(_ fd: inout Int32) {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}
