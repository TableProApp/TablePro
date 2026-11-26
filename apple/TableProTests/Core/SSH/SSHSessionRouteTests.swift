//
//  SSHSessionRouteTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
@testable import TableProSSHConfig
import TableProSSHTransport
import Testing

struct SSHSessionRouteTests {
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

    private static func route(
        host: String = "db",
        username: String = "",
        authMethod: SSHAuthMethod = .password,
        jumpHosts: [SSHJumpHost] = [],
        password: String? = "secret",
        destination: SSHForwardDestination = .tcp(host: "127.0.0.1", port: 5_432)
    ) throws -> SSHSessionRoute {
        let configuration = SSHConfiguration(
            enabled: true,
            host: host,
            username: username,
            authMethod: authMethod,
            jumpHosts: jumpHosts
        )
        let resolved = try LibSSH2TunnelFactory.resolveChainConfiguration(
            config: configuration,
            document: SSHConfigParser.parseDocumentContent(config),
            env: env
        )
        return SSHSessionRoute(
            config: configuration,
            resolved: resolved,
            credentials: SSHTunnelCredentials(
                sshPassword: password,
                keyPassphrase: nil,
                totpSecret: nil,
                keyboardInteractivePromptProvider: nil
            ),
            destination: destination
        )
    }

    @Test("Two connections to the same host, user and password share a route, jump hops from the config included")
    func sameSignInSharesRoute() throws {
        let first = try Self.route()
        let second = try Self.route()

        #expect(first == second)
        #expect(first.hops.map(\.host) == ["b.example", "10.0.0.5"])
    }

    @Test("Form jump hosts typed twice share a route although each has its own id")
    func formJumpIdsDoNotSplitRoute() throws {
        let first = try Self.route(host: "10.0.0.9", username: "app", jumpHosts: [SSHJumpHost(host: "b.example", username: "jump")])
        let second = try Self.route(host: "10.0.0.9", username: "app", jumpHosts: [SSHJumpHost(host: "b.example", username: "jump")])

        #expect(first == second)
    }

    @Test("A different password, user, sign-in method or host gets its own session")
    func anyDifferenceSplitsRoute() throws {
        let base = try Self.route()

        #expect(try Self.route(password: "other") != base)
        #expect(try Self.route(password: nil) != base)
        #expect(try Self.route(username: "admin") != base)
        #expect(try Self.route(authMethod: .sshAgent) != base)
        #expect(try Self.route(host: "bastion") != base)
    }

    @Test("Another database behind the same bastion gets its own session")
    func otherDestinationSplitsRoute() throws {
        let base = try Self.route()

        #expect(try Self.route(destination: .tcp(host: "127.0.0.1", port: 3_306)) != base)
        #expect(try Self.route(destination: .unixSocket(path: "/var/run/postgresql/.s.PGSQL.5432")) != base)
    }

    @Test("The route keeps a digest of the secrets, never the secret itself")
    func routeHoldsNoSecret() throws {
        let route = try Self.route(password: "hunter2-password")

        #expect(route.secretsDigest.count == 32)
        #expect(!String(describing: route).contains("hunter2-password"))
    }
}
