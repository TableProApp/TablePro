//
//  DialedSSHRoute.swift
//  TablePro
//

import Foundation
import TableProSSHConfig
import TableProSSHTransport

struct DialedSSHRoute: Sendable, Equatable {
    let input: PublishedSSHRoute.Input
    let hops: [PublishedSSHRoute.Hop]
    let target: PublishedSSHRoute.Target

    func published(by publisher: UUID) -> PublishedSSHRoute {
        PublishedSSHRoute(publisher: publisher, input: input, hops: hops, target: target)
    }

    // A Mac whose config adds nothing clears only a route it published itself, so a second Mac
    // without the alias cannot wipe what the first one published.
    func routeToStore(replacing stored: PublishedSSHRoute?, publisher: UUID) -> PublishedSSHRoute? {
        let fresh = published(by: publisher)
        if fresh.addsNothing(to: input) {
            return stored?.publisher == publisher ? nil : stored
        }
        if let stored, stored.leadsToSameHosts(as: fresh) {
            return stored
        }
        return fresh
    }
}

extension SSHConfiguration {
    var publishedRouteInput: PublishedSSHRoute.Input {
        PublishedSSHRoute.Input(
            host: host,
            port: port,
            username: username,
            jumpHosts: jumpHosts.map { .init(id: $0.id, host: $0.host, port: $0.port, username: $0.username) }
        )
    }
}
