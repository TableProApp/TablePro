//
//  ConnectionTreeActivationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectionTreeActivationResolver")
struct ConnectionTreeActivationTests {
    @Test("Opening a connection that is not up yet connects it")
    func disclosureConnects() {
        for status in [ConnectionTreeStatus.notConnected, .failed] {
            #expect(
                ConnectionTreeActivationResolver.resolve(status: status, gesture: .disclosure(isExpanded: false))
                    == .connect
            )
            #expect(
                ConnectionTreeActivationResolver.resolve(status: status, gesture: .doubleClick) == .connect
            )
        }
    }

    @Test("A connected row just opens")
    func connectedExpands() {
        #expect(
            ConnectionTreeActivationResolver.resolve(status: .connected, gesture: .disclosure(isExpanded: false))
                == .expand
        )
        #expect(ConnectionTreeActivationResolver.resolve(status: .connected, gesture: .doubleClick) == .expand)
    }

    @Test("Closing a row is closing a row, whatever the session is doing")
    func collapseAlwaysWins() {
        for status in [ConnectionTreeStatus.notConnected, .connecting, .connected, .failed] {
            #expect(
                ConnectionTreeActivationResolver.resolve(status: status, gesture: .disclosure(isExpanded: true))
                    == .collapse
            )
        }
    }

    @Test("A second click while connecting does not abandon the connect")
    func connectingIgnoresDoubleClick() {
        #expect(ConnectionTreeActivationResolver.resolve(status: .connecting, gesture: .doubleClick) == .nothing)
        #expect(
            ConnectionTreeActivationResolver.resolve(status: .connecting, gesture: .disclosure(isExpanded: false))
                == .nothing
        )
    }

    @Test("A single click only moves the selection")
    func singleClickSelects() {
        for status in [ConnectionTreeStatus.notConnected, .connecting, .connected, .failed] {
            #expect(ConnectionTreeActivationResolver.resolve(status: status, gesture: .singleClick) == .select)
        }
    }

    @Test("A folder only opens and closes")
    func groupToggles() {
        #expect(ConnectionTreeActivationResolver.resolveGroup(gesture: .doubleClick, isExpanded: false) == .expand)
        #expect(ConnectionTreeActivationResolver.resolveGroup(gesture: .doubleClick, isExpanded: true) == .collapse)
        #expect(
            ConnectionTreeActivationResolver.resolveGroup(gesture: .disclosure(isExpanded: false), isExpanded: false)
                == .expand
        )
        #expect(ConnectionTreeActivationResolver.resolveGroup(gesture: .singleClick, isExpanded: false) == .select)
    }
}

@Suite("ConnectionTreeAutoExpansion")
struct ConnectionTreeAutoExpansionTests {
    /// `consume` mutates, and `#expect` captures its argument expression to report it, which makes
    /// the captured copy immutable. Every call is made on its own line for that reason.
    @Test("A connection opened by the user expands when its connect lands")
    func expandsOnConnect() {
        var expansion = ConnectionTreeAutoExpansion()
        let id = UUID()
        expansion.expect(id)
        let didExpand = expansion.consume(id, status: .connected)
        #expect(didExpand)
    }

    @Test("It expands once, so a later reconnect does not reopen a collapsed tree")
    func expandsOnlyOnce() {
        var expansion = ConnectionTreeAutoExpansion()
        let id = UUID()
        expansion.expect(id)
        let first = expansion.consume(id, status: .connected)
        let second = expansion.consume(id, status: .connected)
        #expect(first)
        #expect(!second)
        #expect(expansion.isEmpty)
    }

    @Test("Still connecting is not yet the moment to expand")
    func waitsWhileConnecting() {
        var expansion = ConnectionTreeAutoExpansion()
        let id = UUID()
        expansion.expect(id)
        let whileConnecting = expansion.consume(id, status: .connecting)
        let onceConnected = expansion.consume(id, status: .connected)
        #expect(!whileConnecting)
        #expect(onceConnected)
    }

    @Test("A failed connect drops the intent rather than holding it for the next one")
    func failureClearsIntent() {
        var expansion = ConnectionTreeAutoExpansion()
        let id = UUID()
        expansion.expect(id)
        let onFailure = expansion.consume(id, status: .failed)
        #expect(!onFailure)
        #expect(expansion.isEmpty)
        let afterFailure = expansion.consume(id, status: .connected)
        #expect(!afterFailure)
    }

    @Test("A connection nobody opened is left closed when it connects on its own")
    func ignoresUnexpectedConnections() {
        var expansion = ConnectionTreeAutoExpansion()
        let unexpected = expansion.consume(UUID(), status: .connected)
        #expect(!unexpected)
    }

    @Test("Cancelling takes the intent back")
    func cancelDropsIntent() {
        var expansion = ConnectionTreeAutoExpansion()
        let id = UUID()
        expansion.expect(id)
        expansion.cancel(id)
        let afterCancel = expansion.consume(id, status: .connected)
        #expect(!afterCancel)
    }
}
