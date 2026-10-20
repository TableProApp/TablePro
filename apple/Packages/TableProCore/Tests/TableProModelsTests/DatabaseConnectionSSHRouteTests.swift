import Foundation
@testable import TableProModels
import TableProSSHTransport
import Testing

struct DatabaseConnectionSSHRouteTests {
    private static let bastionId = PublishedSSHRoute.derivedHopId(alias: "bastion", occurrence: 0)

    private static func aliasConnection() -> DatabaseConnection {
        let ssh = SSHConfiguration(host: "db", username: "")
        var connection = DatabaseConnection(
            name: "Alias",
            type: .postgresql,
            host: "127.0.0.1",
            port: 5_432,
            sshEnabled: true,
            sshConfiguration: ssh
        )
        connection.sshRoute = macRoute(for: ssh)
        return connection
    }

    private static func macRoute(for configuration: SSHConfiguration) -> PublishedSSHRoute {
        PublishedSSHRoute(
            publisher: UUID(),
            input: configuration.publishedRouteInput,
            hops: [.init(id: bastionId, alias: "bastion", host: "b.example", port: 22, username: "jump")],
            target: .init(alias: "db", host: "10.0.0.5", port: 2_222, username: "deploy")
        )
    }

    @Test("A route the Mac dialed for this tunnel is what this device dials")
    func dialsTheMacRoute() throws {
        let dialed = try #require(Self.aliasConnection().sshConfigurationForDialing)

        #expect(dialed.host == "10.0.0.5")
        #expect(dialed.port == 2_222)
        #expect(dialed.username == "deploy")
        #expect(dialed.jumpHosts.map(\.id) == [Self.bastionId])
        #expect(dialed.jumpHosts.map(\.host) == ["b.example"])
        #expect(dialed.jumpHosts.map(\.username) == ["jump"])
    }

    @Test("Once the tunnel is edited the route no longer applies and the typed host is dialed")
    func editedTunnelIgnoresTheRoute() throws {
        var connection = Self.aliasConnection()
        connection.sshConfiguration?.host = "db.example"

        let dialed = try #require(connection.sshConfigurationForDialing)
        #expect(dialed.host == "db.example")
        #expect(dialed.jumpHosts.isEmpty)
        #expect(connection.sshRouteInEffect == nil)
    }

    @Test("A typed hop the route resolved keeps its Mac sign-in fields")
    func typedHopKeepsMacFields() throws {
        let typedHop = SSHJumpHost(host: "bastion", macAuthMethod: .privateKey, macPrivateKeyPath: "~/.ssh/b")
        let ssh = SSHConfiguration(host: "db", username: "deploy", jumpHosts: [typedHop])
        var connection = DatabaseConnection(name: "Typed hop", type: .postgresql, sshEnabled: true, sshConfiguration: ssh)
        connection.sshRoute = PublishedSSHRoute(
            publisher: UUID(),
            input: ssh.publishedRouteInput,
            hops: [.init(id: typedHop.id, alias: "bastion", host: "b.example", port: 22, username: "jump")],
            target: .init(alias: "db", host: "10.0.0.5", port: 22, username: "deploy")
        )

        let hop = try #require(connection.sshConfigurationForDialing?.jumpHosts.first)
        #expect(hop.id == typedHop.id)
        #expect(hop.host == "b.example")
        #expect(hop.macAuthMethod == .privateKey)
        #expect(hop.macPrivateKeyPath == "~/.ssh/b")
    }

    @Test("A route that only repeats the typed hosts changes nothing")
    func trivialRouteIsNotInEffect() {
        let ssh = SSHConfiguration(host: "10.0.0.5", username: "deploy")
        var connection = DatabaseConnection(name: "Plain", type: .postgresql, sshEnabled: true, sshConfiguration: ssh)
        connection.sshRoute = PublishedSSHRoute(
            publisher: UUID(),
            input: ssh.publishedRouteInput,
            hops: [],
            target: .init(alias: "10.0.0.5", host: "10.0.0.5", port: 22, username: "deploy")
        )
        #expect(connection.sshRouteInEffect == nil)
    }

    @Test("A route and profile link survive the device's own storage")
    func routeSurvivesLocalStorage() throws {
        var connection = Self.aliasConnection()
        connection.sshProfileId = UUID()
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(connection))

        #expect(decoded.sshRoute == connection.sshRoute)
        #expect(decoded.sshProfileId == connection.sshProfileId)
    }

    @Test("A Mac socket forward is the tunnel's destination, and host and port go unused")
    func socketForwardIsTheDestination() {
        var connection = Self.aliasConnection()
        #expect(connection.sshForwardDestination == .tcp(host: "127.0.0.1", port: 5_432))

        connection.additionalFields[DatabaseConnection.sshForwardUnixSocketPathKey] = "/var/run/postgresql/.s.PGSQL.5432"
        #expect(connection.sshForwardDestination == .unixSocket(path: "/var/run/postgresql/.s.PGSQL.5432"))
    }
}
