//
//  TableAutoRefreshIntervalTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TableAutoRefreshIntervalTests {
    @Test("The presets run from five seconds to five minutes, after Off")
    func presets() {
        let seconds = TableAutoRefreshInterval.allCases.map { $0.rawValue }
        #expect(seconds == [0, 5, 10, 30, 60, 300])
        #expect(TableAutoRefreshInterval.allCases.filter { !$0.isOn } == [.off])
        #expect(TableAutoRefreshInterval.oneMinute.duration == .seconds(60))
    }

    @Test("Each preset has its own title")
    func titles() {
        let titles = TableAutoRefreshInterval.allCases.map { $0.title }
        #expect(titles == [
            "Off", "Every 5 Seconds", "Every 10 Seconds", "Every 30 Seconds", "Every Minute", "Every 5 Minutes",
        ])
    }

    @Test("An auto refresh writes no history and keeps the count; every other load does both")
    func autoRefreshTriggerSkipsHistoryAndCount() {
        #expect(!TableLoadTrigger.autoRefresh.recordsHistory)
        #expect(!TableLoadTrigger.autoRefresh.countsRows)
        #expect(TableLoadTrigger.userInitiated.recordsHistory)
        #expect(TableLoadTrigger.restore.countsRows)
    }

    @Test("A table tab never saves its interval, so a reopened tab starts with it off")
    func intervalIsSessionOnly() {
        var tab = QueryTab(title: "jobs", query: "SELECT * FROM jobs", tabType: .table, tableName: "jobs")
        tab.autoRefreshInterval = .fiveSeconds

        let reopened = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)
        var stopped = tab
        stopped.autoRefreshInterval = .off

        #expect(reopened.autoRefreshInterval == .off)
        #expect(tab != stopped, "a view keyed on the tab has to see the interval change")
    }
}
