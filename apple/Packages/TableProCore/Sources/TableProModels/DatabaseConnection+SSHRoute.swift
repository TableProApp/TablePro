import Foundation
import TableProSSHTransport

public extension SSHConfiguration {
    var publishedRouteInput: PublishedSSHRoute.Input {
        PublishedSSHRoute.Input(
            host: host,
            port: port,
            username: username,
            jumpHosts: jumpHosts.map { .init(id: $0.id, host: $0.host, port: $0.port, username: $0.username) }
        )
    }

    // The Mac's route, when it still describes this configuration and reaches anything the typed
    // hosts do not.
    func routeInEffect(_ route: PublishedSSHRoute?) -> PublishedSSHRoute? {
        let input = publishedRouteInput
        guard let route, route.describes(input), !route.addsNothing(to: input) else { return nil }
        return route
    }

    // Hops keep the route's ids, which is what their keys on this device are stored under.
    func dialing(_ route: PublishedSSHRoute) -> SSHConfiguration {
        var dialed = self
        dialed.host = route.target.host
        dialed.port = route.target.port
        dialed.username = route.target.username
        let typed = Dictionary(jumpHosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        dialed.jumpHosts = route.hops.map { hop in
            var jumpHost = typed[hop.id] ?? SSHJumpHost(id: hop.id)
            jumpHost.host = hop.host
            jumpHost.port = hop.port
            jumpHost.username = hop.username
            return jumpHost
        }
        return dialed
    }
}

public extension DatabaseConnection {
    var sshRouteInEffect: PublishedSSHRoute? {
        sshConfiguration?.routeInEffect(sshRoute)
    }

    var sshConfigurationForDialing: SSHConfiguration? {
        guard let configuration = sshConfiguration else { return nil }
        guard let route = configuration.routeInEffect(sshRoute) else { return configuration }
        return configuration.dialing(route)
    }
}

public extension DatabaseConnection {
    static let sshForwardUnixSocketPathKey = "sshForwardUnixSocketPath"

    // A Mac connection can forward to a socket on the SSH server, which leaves host and port unused.
    var sshForwardUnixSocketPath: String? {
        guard let path = additionalFields[Self.sshForwardUnixSocketPathKey], !path.isEmpty else { return nil }
        return path
    }

    var sshForwardDestination: SSHForwardDestination {
        sshForwardUnixSocketPath.map { .unixSocket(path: $0) } ?? .tcp(host: host, port: port)
    }
}
