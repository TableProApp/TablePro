import Foundation
@testable import TableProSSHTransport
import Testing

struct PublishedSSHRouteTests {
    private static let aliasInput = PublishedSSHRoute.Input(host: "db", port: nil, username: "", jumpHosts: [])

    private static func route(input: PublishedSSHRoute.Input = aliasInput) -> PublishedSSHRoute {
        PublishedSSHRoute(
            publisher: UUID(),
            input: input,
            hops: [PublishedSSHRoute.Hop(
                id: PublishedSSHRoute.derivedHopId(alias: "bastion", occurrence: 0),
                alias: "bastion",
                host: "b.example",
                port: 22,
                username: "jump"
            )],
            target: PublishedSSHRoute.Target(alias: "db", host: "10.0.0.5", port: 22, username: "deploy")
        )
    }

    @Test("The basis is a fixed digest of the input, so both apps compute the same one")
    func basisIsStable() {
        #expect(
            PublishedSSHRoute.basis(of: Self.aliasInput)
                == "1dec90d6fba51b7903e21b91cfa8a45d41cc27724b9c9007e5bdf0bbbbbac595"
        )
    }

    @Test("Any change to the tunnel input changes the basis", arguments: [
        PublishedSSHRoute.Input(host: "db2", port: nil, username: "", jumpHosts: []),
        PublishedSSHRoute.Input(host: "db", port: 22, username: "", jumpHosts: []),
        PublishedSSHRoute.Input(host: "db", port: nil, username: "deploy", jumpHosts: []),
        PublishedSSHRoute.Input(host: "db", port: nil, username: "", jumpHosts: [.init(id: UUID(), host: "b", port: nil, username: "")]),
    ])
    func basisFollowsInput(changed: PublishedSSHRoute.Input) {
        #expect(PublishedSSHRoute.basis(of: changed) != PublishedSSHRoute.basis(of: Self.aliasInput))
    }

    @Test("Field boundaries cannot be shifted to forge the same basis")
    func basisSeparatesFields() {
        let first = PublishedSSHRoute.Input(host: "ab", port: nil, username: "c", jumpHosts: [])
        let second = PublishedSSHRoute.Input(host: "a", port: nil, username: "bc", jumpHosts: [])
        #expect(PublishedSSHRoute.basis(of: first) != PublishedSSHRoute.basis(of: second))
    }

    @Test("A hop deleted and typed again with the same host is a new input")
    func retypedHopChangesTheBasis() {
        let typed = PublishedSSHRoute.Input.JumpHost(id: UUID(), host: "b", port: nil, username: "jump")
        var retyped = typed
        retyped.id = UUID()
        let first = PublishedSSHRoute.Input(host: "db", port: nil, username: "", jumpHosts: [typed])
        let second = PublishedSSHRoute.Input(host: "db", port: nil, username: "", jumpHosts: [retyped])
        #expect(PublishedSSHRoute.basis(of: first) != PublishedSSHRoute.basis(of: second))
    }

    @Test("A route describes only the input it was dialed from")
    func describesItsInput() {
        let route = Self.route()
        #expect(route.describes(Self.aliasInput))
        #expect(!route.describes(PublishedSSHRoute.Input(host: "other", port: nil, username: "", jumpHosts: [])))
    }

    @Test("A route from a newer format is not used")
    func newerVersionIsIgnored() {
        var route = Self.route()
        route.version = PublishedSSHRoute.currentVersion + 1
        #expect(!route.describes(Self.aliasInput))
    }

    @Test("A route that dials the typed hosts adds nothing")
    func trivialRouteAddsNothing() {
        let input = PublishedSSHRoute.Input(
            host: "10.0.0.5",
            port: nil,
            username: "deploy",
            jumpHosts: [.init(id: UUID(), host: "b.example", port: 2_222, username: "jump")]
        )
        let route = PublishedSSHRoute(
            publisher: UUID(),
            input: input,
            hops: [.init(id: UUID(), alias: "b.example", host: "b.example", port: 2_222, username: "jump")],
            target: .init(alias: "10.0.0.5", host: "10.0.0.5", port: 22, username: "deploy")
        )
        #expect(route.addsNothing(to: input))
        #expect(!Self.route().addsNothing(to: Self.aliasInput))
    }

    @Test("A derived hop id is the same on every publish and differs per alias and occurrence")
    func derivedIdsAreStable() {
        let first = PublishedSSHRoute.derivedHopId(alias: "bastion", occurrence: 0)
        #expect(first == PublishedSSHRoute.derivedHopId(alias: "bastion", occurrence: 0))
        #expect(first != PublishedSSHRoute.derivedHopId(alias: "bastion", occurrence: 1))
        #expect(first != PublishedSSHRoute.derivedHopId(alias: "bastion2", occurrence: 0))
    }

    @Test("A route survives an encode and decode")
    func roundTrips() throws {
        let route = Self.route()
        let data = try #require(route.encoded())
        #expect(PublishedSSHRoute.decoded(from: data) == route)
        #expect(PublishedSSHRoute.decoded(from: Data("{}".utf8)) == nil)
    }

    @Test("Two routes to the same hosts match whoever published them")
    func samePathIgnoresPublisher() {
        let first = Self.route()
        var second = Self.route()
        second.publisher = UUID()
        #expect(first.leadsToSameHosts(as: second))
        second.target.host = "10.0.0.6"
        #expect(!first.leadsToSameHosts(as: second))
    }

    @Test("Two Macs naming the same jump host differently reach the same hosts")
    func aliasesDoNotMatter() {
        let first = Self.route()
        var second = Self.route()
        second.hops[0].alias = "jump-host"
        second.hops[0].id = PublishedSSHRoute.derivedHopId(alias: "jump-host", occurrence: 0)
        second.target.alias = "database"
        #expect(first.leadsToSameHosts(as: second))
        second.hops[0].port = 2_222
        #expect(!first.leadsToSameHosts(as: second))
    }
}
