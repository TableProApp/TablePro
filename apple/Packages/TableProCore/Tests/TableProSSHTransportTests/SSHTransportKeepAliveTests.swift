//
//  SSHTransportKeepAliveTests.swift
//  TableProSSHTransportTests
//

import Foundation
import Testing

@testable import TableProSSHTransport

struct SSHTransportKeepAliveTests {
    @Test("A TCP socket gets keepalive with the idle time both apps use")
    func setsKeepAliveOnTCPSocket() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { close(descriptor) }

        #expect(SSHTransportKeepAlive.enable(on: descriptor).isEmpty)
        #expect(option(descriptor, SOL_SOCKET, SO_KEEPALIVE) != 0)
        #expect(option(descriptor, IPPROTO_TCP, TCP_KEEPALIVE) == SSHTransportKeepAlive.idleSeconds)
    }

    @Test("A descriptor that cannot take the options names each refusal")
    func reportsRefusedOptions() {
        let refused = SSHTransportKeepAlive.enable(on: -1)

        #expect(refused.count == 2)
        #expect(refused.first?.hasPrefix("SO_KEEPALIVE") == true)
    }

    private func option(_ descriptor: Int32, _ level: Int32, _ name: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, level, name, &value, &length)
        return value
    }
}
