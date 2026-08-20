//
//  RedisSentinelResolverTests.swift
//  TableProTests
//
//  Reply shapes match what a live Redis 8.10.1 Sentinel answers.
//

import Foundation
import Testing

private let sentinelA = RedisNodeAddress(host: "10.0.0.1", port: 26_379)
private let sentinelB = RedisNodeAddress(host: "10.0.0.2", port: 26_379)
private let sentinelC = RedisNodeAddress(host: "10.0.0.3", port: 26_379)
private let primary = RedisNodeAddress(host: "10.0.0.5", port: 6_379)

private struct StubError: Error {}

private actor FakeSentinelTransport: RedisSentinelTransport {
    typealias Answer = @Sendable (RedisNodeAddress) throws -> RedisSentinelReply

    private let answer: Answer
    private let peers: [RedisNodeAddress]
    private let groups: [String]
    private(set) var asked: [RedisNodeAddress] = []

    init(peers: [RedisNodeAddress] = [], groups: [String] = [], answer: @escaping Answer) {
        self.answer = answer
        self.peers = peers
        self.groups = groups
    }

    func primaryAddress(group: String, at sentinel: RedisNodeAddress) async throws -> RedisSentinelReply {
        asked.append(sentinel)
        return try answer(sentinel)
    }

    func peerSentinels(group: String, at sentinel: RedisNodeAddress) async throws -> [RedisNodeAddress] { peers }

    func monitoredGroups(at sentinel: RedisNodeAddress) async throws -> [String] { groups }

    func recordedAsks() -> [RedisNodeAddress] { asked }
}

@Suite("Redis Sentinel resolver - iteration")
struct RedisSentinelResolverIterationTests {
    @Test("Stops at the first Sentinel that knows the primary")
    func stopsAtFirstAnswer() async throws {
        let transport = FakeSentinelTransport { _ in .address(primary) }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB], group: "mymaster", transport: transport
        )

        let resolution = try await resolver.resolvePrimary()

        #expect(resolution.primary == primary)
        #expect(resolution.answeredBy == sentinelA)
        #expect(await transport.recordedAsks() == [sentinelA])
    }

    @Test("Moves past a Sentinel that cannot be reached")
    func skipsUnreachable() async throws {
        let transport = FakeSentinelTransport { sentinel in
            guard sentinel == sentinelB else { throw StubError() }
            return .address(primary)
        }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB], group: "mymaster", transport: transport
        )

        #expect(try await resolver.resolvePrimary().primary == primary)
        #expect(await transport.recordedAsks() == [sentinelA, sentinelB])
    }

    @Test("Moves past a Sentinel that does not know the group")
    func skipsUnaware() async throws {
        let transport = FakeSentinelTransport { sentinel in
            sentinel == sentinelA ? .primaryUnknown : .address(primary)
        }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB], group: "mymaster", transport: transport
        )

        #expect(try await resolver.resolvePrimary().primary == primary)
    }

    @Test("Remembers the peers a Sentinel reports, so a later resolve can reach one the user never listed")
    func learnsPeers() async throws {
        let transport = FakeSentinelTransport(peers: [sentinelB, sentinelC]) { _ in .address(primary) }
        let resolver = RedisSentinelResolver(sentinels: [sentinelA], group: "mymaster", transport: transport)

        _ = try await resolver.resolvePrimary()

        #expect(resolver.candidates == [sentinelA, sentinelB, sentinelC])
    }

    @Test("A peer the user already listed is not added twice")
    func doesNotDuplicatePeers() async throws {
        let transport = FakeSentinelTransport(peers: [sentinelA, sentinelB]) { _ in .address(primary) }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB], group: "mymaster", transport: transport
        )

        _ = try await resolver.resolvePrimary()

        #expect(resolver.candidates == [sentinelA, sentinelB])
    }
}

@Suite("Redis Sentinel resolver - failures")
struct RedisSentinelResolverFailureTests {
    @Test("No Sentinels configured is its own error")
    func noSentinels() async {
        let resolver = RedisSentinelResolver(
            sentinels: [], group: "mymaster", transport: FakeSentinelTransport { _ in .address(primary) }
        )
        await #expect(throws: RedisSentinelError.noSentinelsConfigured) {
            try await resolver.resolvePrimary()
        }
    }

    @Test("An empty group name is its own error")
    func emptyGroup() async {
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA], group: "  ", transport: FakeSentinelTransport { _ in .address(primary) }
        )
        await #expect(throws: RedisSentinelError.emptyPrimaryGroupName) {
            try await resolver.resolvePrimary()
        }
    }

    @Test("A Sentinel that refuses is reported as a refusal, not as unreachable")
    func refusalIsNotUnreachable() async throws {
        let transport = FakeSentinelTransport { sentinel in
            throw RedisSentinelError.refused(sentinel, detail: "NOAUTH Authentication required.")
        }
        let resolver = RedisSentinelResolver(sentinels: [sentinelA], group: "mymaster", transport: transport)

        do {
            _ = try await resolver.resolvePrimary()
            Issue.record("expected a failure")
        } catch let error as RedisSentinelError {
            guard case .refused(_, let detail) = error else {
                Issue.record("expected refused, got \(error)")
                return
            }
            #expect(detail.contains("NOAUTH"))
        }
    }

    @Test("Every Sentinel unreachable names the ones that were tried")
    func allUnreachable() async throws {
        let transport = FakeSentinelTransport { _ in throw StubError() }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB], group: "mymaster", transport: transport
        )

        do {
            _ = try await resolver.resolvePrimary()
            Issue.record("expected a failure")
        } catch let error as RedisSentinelError {
            guard case .allSentinelsUnreachable(let tried) = error else {
                Issue.record("expected allSentinelsUnreachable, got \(error)")
                return
            }
            #expect(tried == [sentinelA, sentinelB])
        }
    }

    @Test("An unknown group reports the groups the quorum does monitor")
    func unknownGroupListsAlternatives() async throws {
        let transport = FakeSentinelTransport(groups: ["cache", "sessions"]) { _ in .primaryUnknown }
        let resolver = RedisSentinelResolver(sentinels: [sentinelA], group: "typo", transport: transport)

        do {
            _ = try await resolver.resolvePrimary()
            Issue.record("expected a failure")
        } catch let error as RedisSentinelError {
            guard case .primaryUnknown(let group, _, let monitored) = error else {
                Issue.record("expected primaryUnknown, got \(error)")
                return
            }
            #expect(group == "typo")
            #expect(monitored == ["cache", "sessions"])
        }
    }

    @Test("Not knowing the group outranks being unreachable, because it is the more useful message")
    func unknownGroupOutranksUnreachable() async throws {
        let transport = FakeSentinelTransport { sentinel in
            guard sentinel == sentinelA else { throw StubError() }
            return .primaryUnknown
        }
        let resolver = RedisSentinelResolver(
            sentinels: [sentinelA, sentinelB], group: "typo", transport: transport
        )

        do {
            _ = try await resolver.resolvePrimary()
            Issue.record("expected a failure")
        } catch let error as RedisSentinelError {
            guard case .primaryUnknown = error else {
                Issue.record("expected primaryUnknown, got \(error)")
                return
            }
        }
    }
}

@Suite("Redis Sentinel resolver - reply parsing")
struct RedisSentinelReplyParsingTests {
    @Test("A two-element reply is the primary's address")
    func parsesAddress() throws {
        let reply = try RedisSentinelResolver.parseAddressReply(["10.0.0.5", "6379"], from: sentinelA)
        #expect(reply == .address(primary))
    }

    @Test("A nil reply means the Sentinel does not monitor that group")
    func parsesUnknown() throws {
        #expect(try RedisSentinelResolver.parseAddressReply(nil, from: sentinelA) == .primaryUnknown)
    }

    @Test("A reply of the wrong shape is reported rather than guessed at")
    func rejectsWrongShape() {
        #expect(throws: RedisSentinelError.self) {
            try RedisSentinelResolver.parseAddressReply(["10.0.0.5"], from: sentinelA)
        }
    }

    @Test("A missing host is reported")
    func rejectsMissingHost() {
        #expect(throws: RedisSentinelError.self) {
            try RedisSentinelResolver.parseAddressReply([nil, "6379"], from: sentinelA)
        }
    }

    @Test("An unusable port is reported")
    func rejectsBadPort() {
        #expect(throws: RedisSentinelError.self) {
            try RedisSentinelResolver.parseAddressReply(["10.0.0.5", "nope"], from: sentinelA)
        }
        #expect(throws: RedisSentinelError.self) {
            try RedisSentinelResolver.parseAddressReply(["10.0.0.5", "70000"], from: sentinelA)
        }
    }

    @Test("SENTINEL sentinels yields the peer addresses")
    func parsesPeerList() {
        let reply = RedisReply.array([
            .array([
                .string("name"), .string("peer1"),
                .string("ip"), .string("10.0.0.2"),
                .string("port"), .string("26379"),
            ]),
            .array([
                .string("ip"), .string("10.0.0.3"),
                .string("port"), .string("26379"),
            ]),
        ])
        #expect(RedisSentinelResolver.parseNodeMaps(reply) == [sentinelB, sentinelC])
    }

    @Test("An entry missing its address is skipped rather than becoming a bad host")
    func skipsIncompletePeers() {
        let reply = RedisReply.array([.array([.string("name"), .string("peer1")])])
        #expect(RedisSentinelResolver.parseNodeMaps(reply).isEmpty)
    }

    @Test("SENTINEL masters yields the monitored group names")
    func parsesGroupNames() {
        let reply = RedisReply.array([
            .array([.string("name"), .string("mymaster"), .string("ip"), .string("10.0.0.5")]),
            .array([.string("name"), .string("cache")]),
        ])
        #expect(RedisSentinelResolver.parseGroupNames(reply) == ["mymaster", "cache"])
    }
}

@Suite("Redis Sentinel error messages")
struct RedisSentinelErrorPresenterTests {
    @Test("An unknown group names the group and what the quorum monitors")
    func unknownGroupMessage() {
        let message = RedisSentinelErrorPresenter.message(
            for: .primaryUnknown(group: "typo", tried: [sentinelA], monitored: ["mymaster"])
        )
        #expect(message.contains("typo"))
        #expect(message.contains("mymaster"))
    }

    @Test("An unreachable quorum names the addresses that were tried")
    func unreachableMessage() {
        let message = RedisSentinelErrorPresenter.message(for: .allSentinelsUnreachable(tried: [sentinelA, sentinelB]))
        #expect(message.contains("10.0.0.1:26379"))
        #expect(message.contains("10.0.0.2:26379"))
    }

    /// A wrong Sentinel password used to be filed under "unreachable", which sends the user to
    /// check the network instead of the Sentinel Password field.
    @Test("A refusal names the reason the Sentinel gave")
    func refusalKeepsTheReason() {
        let message = RedisSentinelErrorPresenter.message(
            for: .refused(sentinelA, detail: "NOAUTH Authentication required.")
        )
        #expect(message.contains("NOAUTH"))
        #expect(!message.contains("Could not reach"))
    }

    @Test("Every failure produces a message rather than an empty string")
    func everyCaseHasAMessage() {
        let cases: [RedisSentinelError] = [
            .noSentinelsConfigured,
            .emptyPrimaryGroupName,
            .primaryUnknown(group: "g", tried: [sentinelA], monitored: []),
            .allSentinelsUnreachable(tried: [sentinelA]),
            .malformedReply(sentinelA, detail: "bad"),
            .refused(sentinelA, detail: "NOPERM"),
            .deadlineExceeded(tried: [sentinelA]),
        ]
        for error in cases {
            #expect(!RedisSentinelErrorPresenter.message(for: error).isEmpty)
        }
    }
}
