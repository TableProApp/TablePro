//
//  InteractionTraceRecorderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct InteractionTraceRecorderTests {
    private let base = ContinuousClock.now

    private func instant(_ milliseconds: Int) -> ContinuousClock.Instant {
        base.advanced(by: .milliseconds(milliseconds))
    }

    @Test("A trace runs from its start to the frame that shows the answer")
    func endsAtTheFrame() throws {
        var recorder = InteractionTraceRecorder()
        let (sequence, superseded) = recorder.begin(
            .sidebarFilter, key: "c1", subject: "lc_t250", startedAt: instant(0), at: instant(3), uptime: 10
        )
        #expect(superseded == nil)
        #expect(recorder.subject(of: .sidebarFilter, key: "c1") == "lc_t250")

        let awaiting = recorder.awaitFrame(.sidebarFilter, key: "c1")
        #expect(awaiting == sequence)
        let presented = recorder.framePresented(
            .sidebarFilter, sequence: sequence, detail: "rows=100", at: instant(120), uptime: 10.12
        )
        let timing = try #require(presented)

        #expect(timing.outcome == .presented)
        #expect(timing.total == .milliseconds(120))
        #expect(timing.reportLine == "interaction #1 path=sidebarFilter outcome=presented totalMs=120.0 end=10.120 rows=100")
        #expect(recorder.subject(of: .sidebarFilter, key: "c1") == nil)
    }

    @Test("A second start of the same path supersedes the first, and its pending frame ends nothing")
    func secondStartSupersedes() throws {
        var recorder = InteractionTraceRecorder()
        let first = recorder.begin(.quickOpenResult, key: "c1", subject: "lc", startedAt: instant(0), at: instant(0), uptime: 1)
        let awaited = recorder.awaitFrame(.quickOpenResult, key: "c1")
        let pending = try #require(awaited)

        let second = recorder.begin(
            .quickOpenResult, key: "c1", subject: "lc_t", startedAt: instant(30), at: instant(30), uptime: 1.03
        )

        let superseded = try #require(second.superseded)
        #expect(superseded.sequence == first.sequence)
        #expect(superseded.outcome == .superseded)
        let late = recorder.framePresented(.quickOpenResult, sequence: pending, detail: "", at: instant(40), uptime: 1.04)
        #expect(late == nil)
        #expect(recorder.subject(of: .quickOpenResult, key: "c1") == "lc_t")
    }

    @Test("A reload while the frame is pending does not end the trace twice")
    func awaitsOneFrame() {
        var recorder = InteractionTraceRecorder()
        _ = recorder.begin(.sidebarListing, key: "c1", subject: "", startedAt: instant(0), at: instant(0), uptime: 1)

        let first = recorder.awaitFrame(.sidebarListing, key: "c1")
        let second = recorder.awaitFrame(.sidebarListing, key: "c1")
        #expect(first != nil)
        #expect(second == nil)
        #expect(recorder.subject(of: .sidebarListing, key: "c1") == nil)
    }

    @Test("A trace answers only for the connection it started on")
    func keyedByConnection() {
        var recorder = InteractionTraceRecorder()
        _ = recorder.begin(.sidebarExpand, key: "c1", subject: "schema:a", startedAt: instant(0), at: instant(0), uptime: 1)

        #expect(recorder.subject(of: .sidebarExpand, key: "c2") == nil)
        let otherConnection = recorder.awaitFrame(.sidebarExpand, key: "c2")
        #expect(otherConnection == nil)
        #expect(recorder.subject(of: .sidebarExpand, key: "c1") == "schema:a")
    }

    @Test("Paths are traced independently")
    func pathsAreIndependent() {
        var recorder = InteractionTraceRecorder()
        _ = recorder.begin(.completion, key: "", subject: "", startedAt: instant(0), at: instant(0), uptime: 1)
        let other = recorder.begin(.quickOpenPanel, key: "c1", subject: "", startedAt: instant(5), at: instant(5), uptime: 1)

        #expect(other.superseded == nil)
        #expect(recorder.subject(of: .completion, key: "") == "")
    }
}
