//
//  SocketPair.swift
//  TableProTests
//

import Foundation

/// A connected pair of local socket fds, used to drive relay and channel-open tests over
/// real sockets rather than fakes, so closing behaviour is observed the way a database
/// client would observe it.
internal final class SocketPair {
    let a: Int32
    let b: Int32

    init() {
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        a = fds[0]
        b = fds[1]
    }

    func closeB() { Darwin.close(b) }

    func close() {
        Darwin.close(a)
        Darwin.close(b)
    }
}
