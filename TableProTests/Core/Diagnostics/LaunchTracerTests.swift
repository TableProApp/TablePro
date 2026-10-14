//
//  LaunchTracerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
final class LaunchTracerTests {
    @Test
    func marksAreRecordedInOrderWithMonotonicOffsets() {
        let tracer = LaunchTracer(processStart: Date())

        tracer.mark(.main)
        tracer.mark(.applicationCreated)
        tracer.mark(.didFinishLaunchingBegan)

        #expect(tracer.recordedMarks.map(\.stage) == [.main, .applicationCreated, .didFinishLaunchingBegan])
        #expect(tracer.recordedMarks.map(\.offset) == tracer.recordedMarks.map(\.offset).sorted())
    }

    /// Every offset is measured from process exec, so a tracer built with a start in the past
    /// reports that gap rather than starting its clock at first touch.
    @Test
    func offsetsAreMeasuredFromProcessStart() {
        let tracer = LaunchTracer(processStart: Date().addingTimeInterval(-2))

        tracer.mark(.main)

        let offset = try? #require(tracer.recordedMarks.first?.offset)
        #expect((offset ?? 0) > 1.9)
    }

    @Test
    func theFirstFrameEndsTheTraceSoLaterMarksAreIgnored() {
        let tracer = LaunchTracer(processStart: Date())

        tracer.mark(.main)
        tracer.mark(.firstFramePresented)
        tracer.mark(.intentsRouted)

        #expect(tracer.recordedMarks.map(\.stage) == [.main, .firstFramePresented])
    }

    @Test
    func theReportNamesEveryStageItRecorded() {
        let tracer = LaunchTracer(processStart: Date())

        tracer.mark(.main)
        tracer.mark(.menuInstalled)

        let report = tracer.report()
        #expect(report.contains("main"))
        #expect(report.contains("menuInstalled"))
        #expect(!report.contains("intentsRouted"))
    }

    @Test
    func processStartIsInThePast() {
        #expect(LaunchTracer.processStartDate() < Date())
    }
}
