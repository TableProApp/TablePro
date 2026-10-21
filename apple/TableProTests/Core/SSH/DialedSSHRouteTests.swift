import Foundation
import TableProPluginKit
@testable import TablePro
@testable import TableProSSHConfig
import TableProSSHTransport
import Testing

struct DialedSSHRouteTests {
    private static let env = ResolverEnvironment(
        runShell: { _ in true },
        canonicalize: { host, _ in host },
        currentLocalUser: { "tester" },
        localHostname: { "Mac" }
    )

    private static let config = """
    Host db
        HostName 10.0.0.5
        User deploy
        ProxyJump bastion
    Host bastion
        HostName b.example
        User jump
    """

    private static func dialed(
        _ host: String,
        username: String = "",
        content: String = config,
        jumpHosts: [SSHJumpHost] = []
    ) throws -> DialedSSHRoute {
        let configuration = SSHConfiguration(
            enabled: true,
            host: host,
            username: username,
            authMethod: .sshAgent,
            jumpHosts: jumpHosts
        )
        return try LibSSH2TunnelFactory.resolveChainConfiguration(
            config: configuration,
            document: SSHConfigParser.parseDocumentContent(content),
            env: env
        ).dialedRoute(for: configuration)
    }

    @Test("The route is the hosts the Mac dials, with config-only hops under ids that do not change")
    func routeFromConfig() throws {
        let route = try Self.dialed("db")

        #expect(route.target == PublishedSSHRoute.Target(alias: "db", host: "10.0.0.5", port: 22, username: "deploy"))
        #expect(route.hops == [PublishedSSHRoute.Hop(
            id: PublishedSSHRoute.derivedHopId(alias: "bastion", occurrence: 0),
            alias: "bastion",
            host: "b.example",
            port: 22,
            username: "jump"
        )])
        #expect(try Self.dialed("db").hops == route.hops)
        #expect(route.input == PublishedSSHRoute.Input(host: "db", port: nil, username: "", jumpHosts: []))
    }

    @Test("A typed jump host keeps its own id in the route")
    func typedHopKeepsItsId() throws {
        var typed = SSHJumpHost()
        typed.host = "bastion"
        let route = try Self.dialed("db", jumpHosts: [typed])

        #expect(route.hops.map(\.id) == [typed.id])
        #expect(route.hops.map(\.host) == ["b.example"])
    }

    @Test("A hop with no User is refused by name instead of signing in as nobody")
    func hopWithoutUserIsNamed() {
        #expect(throws: SSHTunnelError.usernameMissing(host: "plain")) {
            _ = try Self.dialed("db", content: """
            Host db
                HostName 10.0.0.5
                User deploy
                ProxyJump plain
            """)
        }
    }

    @Test("A route through new hosts is stored for this Mac")
    func newRouteIsStored() throws {
        let publisher = UUID()
        let stored = try Self.dialed("db").routeToStore(replacing: nil, publisher: publisher)

        #expect(stored?.publisher == publisher)
        #expect(stored?.target.host == "10.0.0.5")
    }

    @Test("The same route from another Mac is left as it is")
    func sameRouteIsNotRewritten() throws {
        let dialed = try Self.dialed("db")
        let other = dialed.published(by: UUID())

        #expect(dialed.routeToStore(replacing: other, publisher: UUID()) == other)
    }

    @Test("A Mac whose config adds nothing clears only its own route")
    func trivialRouteClearsOnlyOwn() throws {
        let plain = try Self.dialed("10.0.0.5", username: "deploy", content: "")
        let earlier = try Self.dialed("db")
        let mine = UUID()

        #expect(plain.routeToStore(replacing: earlier.published(by: mine), publisher: mine) == nil)
        let theirs = earlier.published(by: UUID())
        #expect(plain.routeToStore(replacing: theirs, publisher: mine) == theirs)
    }
}
