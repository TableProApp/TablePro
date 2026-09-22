//
//  LoopbackHostTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Loopback host")
struct LoopbackHostTests {
    @Test("The named loopback spellings are loopback")
    func acceptsNames() {
        for host in ["localhost", "LOCALHOST", "localhost.", " localhost ", "::1", "[::1]"] {
            #expect(LoopbackHost.isLoopback(host), "\(host) should be loopback")
        }
    }

    /// The whole of 127.0.0.0/8 is loopback, not only 127.0.0.1. Docker and ddev hand out the rest.
    @Test("The whole 127 range is loopback")
    func acceptsTheWholeRange() {
        for host in ["127.0.0.1", "127.0.0.2", "127.1.2.3", "127.255.255.255"] {
            #expect(LoopbackHost.isLoopback(host), "\(host) should be loopback")
        }
    }

    @Test("A remote host is not loopback")
    func rejectsRemoteHosts() {
        for host in ["api.openai.com", "192.168.1.10", "10.0.0.1", "0.0.0.0", "128.0.0.1", ""] {
            #expect(!LoopbackHost.isLoopback(host), "\(host) should not be loopback")
        }
    }

    @Test("A malformed address is not loopback")
    func rejectsMalformed() {
        for host in ["127.0.0", "127.0.0.1.1", "127.0.0.256", "127.a.b.c", "127..0.1", "localhost:1234"] {
            #expect(!LoopbackHost.isLoopback(host), "\(host) should not be loopback")
        }
    }
}
