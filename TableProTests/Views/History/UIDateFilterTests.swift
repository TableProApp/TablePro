//
//  UIDateFilterTests.swift
//  TableProTests
//
//  Tests for UIDateFilter → DateFilter mapping.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("UIDateFilter")
struct UIDateFilterTests {
    @Test(".today maps to .today")
    func todayMapsToToday() {
        #expect(UIDateFilter.today.toDateFilter == .today)
    }

    @Test(".week maps to .thisWeek")
    func weekMapsToThisWeek() {
        #expect(UIDateFilter.week.toDateFilter == .thisWeek)
    }

    @Test(".month maps to .thisMonth")
    func monthMapsToThisMonth() {
        #expect(UIDateFilter.month.toDateFilter == .thisMonth)
    }

    @Test(".all maps to .all")
    func allMapsToAll() {
        #expect(UIDateFilter.all.toDateFilter == .all)
    }

    @Test("CaseIterable has 4 cases")
    func caseIterableHas4Cases() {
        #expect(UIDateFilter.allCases.count == 4)
    }

    @Test("Each case has non-empty localized title")
    func eachCaseHasNonEmptyTitle() {
        for filter in UIDateFilter.allCases {
            #expect(!filter.title.isEmpty)
        }
    }
}
