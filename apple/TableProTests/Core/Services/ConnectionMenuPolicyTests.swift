//
//  ConnectionMenuPolicyTests.swift
//  TableProTests
//
//  A context menu shows only what applies to the row it was opened on, so Disconnect is absent on a
//  workspace with no live session rather than present and dimmed.
//

import Foundation
@testable import TablePro
import Testing

struct ConnectionMenuPolicyTests {
    @Test("Disconnect is offered for a live session")
    func offeredWhenConnected() {
        #expect(ConnectionMenuPolicy.showsDisconnect(status: .connected))
    }

    @Test("Disconnect is hidden for every state without a live session")
    func hiddenWithoutLiveSession() {
        #expect(!ConnectionMenuPolicy.showsDisconnect(status: .disconnected))
        #expect(!ConnectionMenuPolicy.showsDisconnect(status: .connecting))
        #expect(!ConnectionMenuPolicy.showsDisconnect(status: .error("refused")))
    }

    @Test("Server Dashboard is offered for a live session on an engine that has one")
    func serverDashboardNeedsLiveSessionAndEngine() {
        #expect(ConnectionMenuPolicy.showsServerDashboard(status: .connected, type: .postgresql))
        #expect(!ConnectionMenuPolicy.showsServerDashboard(status: .connected, type: .sqlite))
        #expect(!ConnectionMenuPolicy.showsServerDashboard(status: .disconnected, type: .postgresql))
        #expect(!ConnectionMenuPolicy.showsServerDashboard(status: .error("refused"), type: .postgresql))
    }

    @Test("Query Insights is offered for any live session")
    func queryInsightsNeedsLiveSession() {
        #expect(ConnectionMenuPolicy.showsQueryInsights(status: .connected))
        #expect(!ConnectionMenuPolicy.showsQueryInsights(status: .connecting))
        #expect(!ConnectionMenuPolicy.showsQueryInsights(status: .disconnected))
    }
}
