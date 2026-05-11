//
//  RedisSentinelResolverTests.swift
//  TableProTests
//
//  Tests for RedisSentinelResolver (compiled via symlink from RedisDriverPlugin).
//

import Foundation
import Testing

private actor FakeSentinelTransport: SentinelTransport {
    typealias ReplyFactory = @Sendable (SentinelHostPort) async throws -> SentinelMasterReply

    private let factory: ReplyFactory
    private(set) var calls: [SentinelHostPort] = []

    init(factory: @escaping ReplyFactory) {
        self.factory = factory
    }

    func queryMasterAddress(
        masterName: String,
        at sentinel: SentinelHostPort,
        sentinelUsername: String?,
        sentinelPassword: String?
    ) async throws -> SentinelMasterReply {
        calls.append(sentinel)
        return try await factory(sentinel)
    }

    func recordedCalls() -> [SentinelHostPort] { calls }
}

private struct StubError: Error, Equatable {
    let label: String
}

private let sentinelA = SentinelHostPort(host: "10.0.0.1", port: 26_379)
private let sentinelB = SentinelHostPort(host: "10.0.0.2", port: 26_379)
private let sentinelC = SentinelHostPort(host: "10.0.0.3", port: 26_379)

@Suite("Redis Sentinel Resolver - iteration")
struct RedisSentinelResolverIterationTests {
    @Test("Returns the first sentinel's reply when it has an address")
    func returnsFirstSentinelReply() async throws {
        let master = SentinelHostPort(host: "10.0.0.5", port: 6_379)
        let transport = FakeSentinelTransport { _ in .address(master) }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB],
            masterName: "mymaster",
            sentinelUsername: nil,
            sentinelPassword: nil,
            transport: transport
        )

        let resolved = try await resolver.resolveMaster()

        #expect(resolved == master)
        let calls = await transport.recordedCalls()
        #expect(calls == [sentinelA])
    }

    @Test("Falls over to the next sentinel when earlier ones throw")
    func failsOverToNextSentinel() async throws {
        let master = SentinelHostPort(host: "10.0.0.5", port: 6_379)
        let transport = FakeSentinelTransport { sentinel in
            if sentinel == sentinelA { throw StubError(label: "down") }
            return .address(master)
        }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB, sentinelC],
            masterName: "mymaster",
            sentinelUsername: nil,
            sentinelPassword: nil,
            transport: transport
        )

        let resolved = try await resolver.resolveMaster()

        #expect(resolved == master)
        let calls = await transport.recordedCalls()
        #expect(calls == [sentinelA, sentinelB])
    }

    @Test("All sentinels throwing produces allSentinelsUnreachable with full list")
    func allSentinelsUnreachable() async throws {
        let transport = FakeSentinelTransport { _ in throw StubError(label: "down") }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB, sentinelC],
            masterName: "mymaster",
            sentinelUsername: nil,
            sentinelPassword: nil,
            transport: transport
        )

        await #expect(throws: RedisSentinelResolutionError.allSentinelsUnreachable(
            attempts: [sentinelA, sentinelB, sentinelC]
        )) {
            _ = try await resolver.resolveMaster()
        }
    }

    @Test("All sentinels saying masterUnknown produces masterUnknown, not unreachable")
    func masterUnknownTakesPrecedenceOverUnreachable() async throws {
        let transport = FakeSentinelTransport { _ in .masterUnknown }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB],
            masterName: "mymaster",
            sentinelUsername: nil,
            sentinelPassword: nil,
            transport: transport
        )

        await #expect(throws: RedisSentinelResolutionError.masterUnknown(
            masterName: "mymaster",
            triedSentinels: [sentinelA, sentinelB]
        )) {
            _ = try await resolver.resolveMaster()
        }
    }

    @Test("Mixed unknown and unreachable still surfaces as masterUnknown")
    func mixedUnknownAndUnreachableSurfacesAsMasterUnknown() async throws {
        let transport = FakeSentinelTransport { sentinel in
            if sentinel == sentinelA { throw StubError(label: "down") }
            return .masterUnknown
        }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB],
            masterName: "mymaster",
            sentinelUsername: nil,
            sentinelPassword: nil,
            transport: transport
        )

        await #expect(throws: RedisSentinelResolutionError.masterUnknown(
            masterName: "mymaster",
            triedSentinels: [sentinelB]
        )) {
            _ = try await resolver.resolveMaster()
        }
    }

    @Test("IPv6 master address passes through unchanged")
    func ipv6MasterPassesThrough() async throws {
        let master = SentinelHostPort(host: "fd00::1", port: 6_379)
        let transport = FakeSentinelTransport { _ in .address(master) }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA],
            masterName: "mymaster",
            sentinelUsername: nil,
            sentinelPassword: nil,
            transport: transport
        )

        let resolved = try await resolver.resolveMaster()

        #expect(resolved == master)
    }

    @Test("Empty sentinel list short-circuits without calling transport")
    func emptySentinelList() async throws {
        let transport = FakeSentinelTransport { _ in
            Issue.record("Transport should not be invoked")
            return .masterUnknown
        }
        let resolver = RedisSentinelResolver(
            sentinels: [],
            masterName: "mymaster",
            sentinelUsername: nil,
            sentinelPassword: nil,
            transport: transport
        )

        await #expect(throws: RedisSentinelResolutionError.noSentinelsConfigured) {
            _ = try await resolver.resolveMaster()
        }
        let calls = await transport.recordedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Empty master name short-circuits without calling transport")
    func emptyMasterName() async throws {
        let transport = FakeSentinelTransport { _ in
            Issue.record("Transport should not be invoked")
            return .masterUnknown
        }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA],
            masterName: "",
            sentinelUsername: nil,
            sentinelPassword: nil,
            transport: transport
        )

        await #expect(throws: RedisSentinelResolutionError.emptyMasterName) {
            _ = try await resolver.resolveMaster()
        }
        let calls = await transport.recordedCalls()
        #expect(calls.isEmpty)
    }

    @Test("Sentinel credentials are forwarded to the transport")
    func credentialsAreForwarded() async throws {
        actor Capture {
            var seenUsername: String?
            var seenPassword: String?
            func set(_ user: String?, _ pass: String?) {
                seenUsername = user
                seenPassword = pass
            }
        }
        let capture = Capture()

        final class CapturingTransport: SentinelTransport, @unchecked Sendable {
            let capture: Capture
            init(capture: Capture) { self.capture = capture }
            func queryMasterAddress(
                masterName: String,
                at sentinel: SentinelHostPort,
                sentinelUsername: String?,
                sentinelPassword: String?
            ) async throws -> SentinelMasterReply {
                await capture.set(sentinelUsername, sentinelPassword)
                return .address(SentinelHostPort(host: "10.0.0.5", port: 6_379))
            }
        }

        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA],
            masterName: "mymaster",
            sentinelUsername: "sentineluser",
            sentinelPassword: "s3cret",
            transport: CapturingTransport(capture: capture)
        )

        _ = try await resolver.resolveMaster()

        let user = await capture.seenUsername
        let pass = await capture.seenPassword
        #expect(user == "sentineluser")
        #expect(pass == "s3cret")
    }
}

@Suite("Redis Sentinel Resolver - reply parsing")
struct RedisSentinelReplyParsingTests {
    private let origin = SentinelHostPort(host: "10.0.0.1", port: 26_379)

    @Test("Two-element string array becomes an address")
    func twoElementArray() throws {
        let reply = try RedisSentinelResolver.parseMasterReplyTokens(
            ["10.0.0.5", "6379"],
            from: origin
        )
        #expect(reply == .address(SentinelHostPort(host: "10.0.0.5", port: 6_379)))
    }

    @Test("Nil tokens means master unknown")
    func nilTokensMeansUnknown() throws {
        let reply = try RedisSentinelResolver.parseMasterReplyTokens(nil, from: origin)
        #expect(reply == .masterUnknown)
    }

    @Test("Wrong arity throws malformedReply")
    func wrongArityThrows() {
        #expect(throws: RedisSentinelResolutionError.malformedReply(
            origin,
            detail: "expected 2-element array, got 1"
        )) {
            _ = try RedisSentinelResolver.parseMasterReplyTokens(["10.0.0.5"], from: origin)
        }
    }

    @Test("Non-numeric port throws malformedReply")
    func nonNumericPortThrows() {
        #expect(throws: RedisSentinelResolutionError.malformedReply(
            origin,
            detail: "invalid port banana"
        )) {
            _ = try RedisSentinelResolver.parseMasterReplyTokens(["10.0.0.5", "banana"], from: origin)
        }
    }

    @Test("Port out of range throws malformedReply")
    func portOutOfRangeThrows() {
        #expect(throws: RedisSentinelResolutionError.malformedReply(
            origin,
            detail: "invalid port 70000"
        )) {
            _ = try RedisSentinelResolver.parseMasterReplyTokens(["10.0.0.5", "70000"], from: origin)
        }
    }

    @Test("Empty host throws malformedReply")
    func emptyHostThrows() {
        #expect(throws: RedisSentinelResolutionError.malformedReply(origin, detail: "missing host")) {
            _ = try RedisSentinelResolver.parseMasterReplyTokens(["", "6379"], from: origin)
        }
    }
}

@Suite("Redis Sentinel Resolver - hostList parsing")
struct RedisSentinelHostListParsingTests {
    @Test("Comma-separated host:port entries parse in order")
    func basicCommaSeparated() {
        let parsed = RedisSentinelResolver.parseSentinelHostList(
            "10.0.0.1:26379,10.0.0.2:26379",
            defaultPort: 26_379
        )
        #expect(parsed == [
            SentinelHostPort(host: "10.0.0.1", port: 26_379),
            SentinelHostPort(host: "10.0.0.2", port: 26_379),
        ])
    }

    @Test("Entries without an explicit port get the default")
    func defaultPortApplied() {
        let parsed = RedisSentinelResolver.parseSentinelHostList(
            "sentinel-a,sentinel-b:26380",
            defaultPort: 26_379
        )
        #expect(parsed == [
            SentinelHostPort(host: "sentinel-a", port: 26_379),
            SentinelHostPort(host: "sentinel-b", port: 26_380),
        ])
    }

    @Test("Whitespace around entries is trimmed; empty segments are skipped")
    func whitespaceAndEmpties() {
        let parsed = RedisSentinelResolver.parseSentinelHostList(
            " 10.0.0.1:26379 , ,10.0.0.2 ",
            defaultPort: 26_379
        )
        #expect(parsed == [
            SentinelHostPort(host: "10.0.0.1", port: 26_379),
            SentinelHostPort(host: "10.0.0.2", port: 26_379),
        ])
    }

    @Test("IPv6 address in brackets with port")
    func ipv6Bracketed() {
        let parsed = RedisSentinelResolver.parseSentinelHostList(
            "[fd00::1]:26379",
            defaultPort: 26_379
        )
        #expect(parsed == [SentinelHostPort(host: "fd00::1", port: 26_379)])
    }

    @Test("IPv6 address in brackets without port uses default")
    func ipv6BracketedDefaultPort() {
        let parsed = RedisSentinelResolver.parseSentinelHostList(
            "[fd00::1]",
            defaultPort: 26_379
        )
        #expect(parsed == [SentinelHostPort(host: "fd00::1", port: 26_379)])
    }

    @Test("Bare IPv6 address with multiple colons falls through to host-only")
    func bareIpv6FallsThroughAsHostOnly() {
        let parsed = RedisSentinelResolver.parseSentinelHostList(
            "fd00::1",
            defaultPort: 26_379
        )
        #expect(parsed == [SentinelHostPort(host: "fd00::1", port: 26_379)])
    }
}
