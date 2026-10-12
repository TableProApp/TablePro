//
//  ConnectionFormChildObservationTests.swift
//  TableProTests
//
//  Every connection form pane observes the coordinator and reads its values through a child view
//  model. A change inside a child that never reached the coordinator's publisher left the pane as
//  it was drawn, which is how picking Sentinel kept the Redis mode picker on Standalone.
//

import Combine
import Foundation
import Testing

@testable import TablePro

@MainActor
struct ConnectionFormChildObservationTests {
    private final class ChangeCounter {
        private(set) var sends = 0
        private var subscription: AnyCancellable?

        init(_ coordinator: ConnectionFormCoordinator) {
            subscription = coordinator.objectWillChange.sink { [weak self] in self?.sends += 1 }
        }
    }

    private func children(of coordinator: ConnectionFormCoordinator) -> [(String, ObservableObjectPublisher)] {
        [
            ("network", coordinator.network.objectWillChange),
            ("auth", coordinator.auth.objectWillChange),
            ("ssh", coordinator.ssh.objectWillChange),
            ("remoteFile", coordinator.remoteFile.objectWillChange),
            ("cloudflareTunnel", coordinator.cloudflareTunnel.objectWillChange),
            ("cloudSQLProxy", coordinator.cloudSQLProxy.objectWillChange),
            ("socksProxy", coordinator.socksProxy.objectWillChange),
            ("tunnelCommand", coordinator.tunnelCommand.objectWillChange),
            ("ssl", coordinator.ssl.objectWillChange),
            ("customization", coordinator.customization.objectWillChange),
            ("advanced", coordinator.advanced.objectWillChange),
            ("aiRules", coordinator.aiRules.objectWillChange),
        ]
    }

    @Test("a value changed inside a child reaches the coordinator's observers")
    func childValueChangeReachesCoordinator() {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        let counter = ChangeCounter(coordinator)

        coordinator.network.additionalFieldValues["redisMode"] = "sentinel"

        #expect(counter.sends == 1)
    }

    @Test("every child forwards its changes")
    func everyChildForwards() {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)

        for (name, publisher) in children(of: coordinator) {
            let counter = ChangeCounter(coordinator)
            publisher.send()
            #expect(counter.sends == 1, "\(name) did not reach the coordinator")
        }
    }

    @Test("a replaced child forwards, and the one it replaced goes quiet")
    func replacedChildForwards() {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        let replaced = coordinator.network
        let replacement = NetworkPaneViewModel()
        coordinator.network = replacement
        let counter = ChangeCounter(coordinator)

        replaced.type = .postgresql
        #expect(counter.sends == 0)

        replacement.type = .postgresql
        #expect(counter.sends == 1)
    }
}
