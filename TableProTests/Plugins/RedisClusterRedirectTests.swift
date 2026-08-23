//
//  RedisClusterRedirectTests.swift
//  TableProTests
//
//  The error strings here were captured from a live Redis 8.10.1 cluster, including the endpoint
//  forms a node uses when it cannot announce its own address.
//

import Foundation
import Testing

@Suite("Redis cluster redirect - MOVED and ASK")
struct RedisClusterRedirectParsingTests {
    @Test("Parses a MOVED with a full endpoint")
    func parsesMoved() {
        let redirect = RedisClusterRedirect.parse("MOVED 12182 127.0.0.1:7103", fallbackHost: "10.0.0.1")
        #expect(redirect == .moved(slot: 12_182, address: RedisNodeAddress(host: "127.0.0.1", port: 7_103)))
    }

    @Test("Parses an ASK with a full endpoint")
    func parsesAsk() {
        let redirect = RedisClusterRedirect.parse("ASK 12182 127.0.0.1:7101", fallbackHost: "10.0.0.1")
        #expect(redirect == .ask(slot: 12_182, address: RedisNodeAddress(host: "127.0.0.1", port: 7_101)))
    }

    @Test("An empty endpoint host reuses the node that answered")
    func emptyHostFallsBack() {
        let redirect = RedisClusterRedirect.parse("MOVED 3999 :6380", fallbackHost: "10.0.0.9")
        #expect(redirect?.address == RedisNodeAddress(host: "10.0.0.9", port: 6_380))
    }

    @Test("A question-mark endpoint reuses the node that answered")
    func unknownHostFallsBack() {
        let redirect = RedisClusterRedirect.parse("MOVED 3999 ?:7103", fallbackHost: "10.0.0.9")
        #expect(redirect?.address == RedisNodeAddress(host: "10.0.0.9", port: 7_103))
    }

    @Test("An unbracketed IPv6 literal keeps every group")
    func bareIPv6() {
        let redirect = RedisClusterRedirect.parse("MOVED 100 ::1:7302", fallbackHost: "10.0.0.1")
        #expect(redirect?.address == RedisNodeAddress(host: "::1", port: 7_302))
    }

    @Test("A bracketed IPv6 literal loses its brackets")
    func bracketedIPv6() {
        let redirect = RedisClusterRedirect.parse("MOVED 100 [fe80::1]:7302", fallbackHost: "10.0.0.1")
        #expect(redirect?.address == RedisNodeAddress(host: "fe80::1", port: 7_302))
    }

    @Test("Carries the slot so the topology can be patched")
    func exposesSlot() {
        #expect(RedisClusterRedirect.parse("MOVED 12182 127.0.0.1:7103", fallbackHost: "h")?.slot == 12_182)
    }
}

@Suite("Redis cluster redirect - other control errors")
struct RedisClusterRedirectControlTests {
    @Test("Parses TRYAGAIN with its slot")
    func parsesTryAgain() {
        let redirect = RedisClusterRedirect.parse("TRYAGAIN 13513 Multiple keys request", fallbackHost: "h")
        #expect(redirect == .tryAgain(slot: 13_513))
    }

    @Test("Parses TRYAGAIN without a slot")
    func parsesBareTryAgain() {
        #expect(RedisClusterRedirect.parse("TRYAGAIN", fallbackHost: "h") == .tryAgain(slot: nil))
    }

    @Test("Parses CLUSTERDOWN and keeps its detail")
    func parsesClusterDown() {
        let redirect = RedisClusterRedirect.parse("CLUSTERDOWN Hash slot not served", fallbackHost: "h")
        #expect(redirect == .clusterDown("Hash slot not served"))
    }

    @Test("Parses the exact CROSSSLOT text Redis sends")
    func parsesCrossSlot() {
        let message = "CROSSSLOT Keys in request don't hash to the same slot"
        #expect(RedisClusterRedirect.parse(message, fallbackHost: "h") == .crossSlot)
    }
}

@Suite("Redis cluster redirect - non-redirects")
struct RedisClusterRedirectRejectionTests {
    static let notRedirects = [
        "WRONGTYPE Operation against a key holding the wrong kind of value",
        "ERR unknown command 'blah'",
        "NOPERM this user has no permissions",
        "READONLY You can't write against a read only replica.",
        "",
    ]

    @Test("Ordinary server errors are not redirects", arguments: notRedirects)
    func ignoresOtherErrors(message: String) {
        #expect(RedisClusterRedirect.parse(message, fallbackHost: "h") == nil)
    }

    @Test("A MOVED without an endpoint is rejected rather than half-parsed")
    func rejectsMissingEndpoint() {
        #expect(RedisClusterRedirect.parse("MOVED 12182", fallbackHost: "h") == nil)
    }

    @Test("A non-numeric slot is rejected")
    func rejectsBadSlot() {
        #expect(RedisClusterRedirect.parse("MOVED abc 127.0.0.1:7103", fallbackHost: "h") == nil)
    }

    @Test("A port outside the legal range is rejected")
    func rejectsBadPort() {
        #expect(RedisClusterRedirect.parse("MOVED 1 127.0.0.1:70000", fallbackHost: "h") == nil)
    }
}
