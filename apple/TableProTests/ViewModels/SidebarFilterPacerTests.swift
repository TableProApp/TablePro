//
//  SidebarFilterPacerTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct SidebarFilterPacerTests {
    @Test("Before any refresh a key applies at once")
    func noRefreshMeansNoWait() {
        #expect(SidebarFilterPacer().delay(at: .milliseconds(5)) == .zero)
    }

    @Test("A 40 ms refresh that ended 100 ms ago leaves no wait")
    func oldShortRefreshLeavesNoWait() {
        var pacer = SidebarFilterPacer()
        pacer.recordRefresh(start: .milliseconds(0), end: .milliseconds(40))
        #expect(pacer.delay(at: .milliseconds(140)) == .zero)
    }

    @Test("A 40 ms refresh that ended 10 ms ago leaves 30 ms")
    func recentShortRefreshLeavesTheRest() {
        var pacer = SidebarFilterPacer()
        pacer.recordRefresh(start: .milliseconds(0), end: .milliseconds(40))
        #expect(pacer.delay(at: .milliseconds(50)) == .milliseconds(30))
    }

    @Test("A 400 ms refresh waits 150 ms from its end")
    func longRefreshWaitIsCapped() {
        var pacer = SidebarFilterPacer()
        pacer.recordRefresh(start: .milliseconds(0), end: .milliseconds(400))
        #expect(pacer.delay(at: .milliseconds(400)) == .milliseconds(150))
        #expect(pacer.delay(at: .milliseconds(550)) == .zero)
    }

    @Test("The latest refresh decides the wait")
    func latestRefreshWins() {
        var pacer = SidebarFilterPacer()
        pacer.recordRefresh(start: .milliseconds(0), end: .milliseconds(400))
        pacer.recordRefresh(start: .milliseconds(500), end: .milliseconds(510))
        #expect(pacer.delay(at: .milliseconds(515)) == .milliseconds(5))
    }
}
