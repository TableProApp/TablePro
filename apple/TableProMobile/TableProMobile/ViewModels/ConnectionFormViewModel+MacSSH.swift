import Foundation
import TableProModels
import TableProSSHTransport

extension ConnectionFormViewModel {
    // Follows the form as it is typed: once the tunnel fields stop being the ones the Mac dialed
    // from, the route no longer describes them and the typed hosts are dialed instead.
    var macRoute: PublishedSSHRoute? {
        guard sshEnabled else { return nil }
        let typed = SSHConfiguration(
            host: sshHost,
            port: Int(sshPort),
            username: sshUsername,
            jumpHosts: jumpHosts.map { SSHJumpHost(id: $0.id, host: $0.host, port: Int($0.port), username: $0.username) }
        )
        return typed.routeInEffect(existingConnection?.sshRoute)
    }

    // The Mac rebuilds a profile-linked tunnel from the profile on every connect, so an edit here
    // would be undone; the server, its sign-in method and the hops are the profile's.
    var sshFollowsMacProfile: Bool {
        sshEnabled && existingConnection?.sshProfileId != nil
    }

    func isRouteOnlyHop(_ id: UUID) -> Bool {
        routeHops.contains { $0.id == id }
    }

    func hostFieldsAreReadOnly(forHop id: UUID) -> Bool {
        isRouteOnlyHop(id) || sshFollowsMacProfile
    }
}
