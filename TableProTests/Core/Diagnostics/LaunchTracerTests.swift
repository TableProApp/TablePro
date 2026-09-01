//
//  LaunchTracerTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

@MainActor
final class LaunchTracerTests: XCTestCase {
    func testMarksAreRecordedInOrderWithMonotonicOffsets() {
        let tracer = LaunchTracer(processStart: Date())

        tracer.mark(.main)
        tracer.mark(.applicationCreated)
        tracer.mark(.didFinishLaunchingBegan)

        XCTAssertEqual(tracer.recordedMarks.map(\.stage), [.main, .applicationCreated, .didFinishLaunchingBegan])
        XCTAssertEqual(tracer.recordedMarks.map(\.offset), tracer.recordedMarks.map(\.offset).sorted())
    }

    /// Every offset is measured from process exec, so a tracer built with a start in the past
    /// reports that gap rather than starting its clock at first touch.
    func testOffsetsAreMeasuredFromProcessStart() {
        let tracer = LaunchTracer(processStart: Date().addingTimeInterval(-2))

        tracer.mark(.main)

        let offset = try? XCTUnwrap(tracer.recordedMarks.first?.offset)
        XCTAssertGreaterThan(offset ?? 0, 1.9)
    }

    func testTheFirstFrameEndsTheTraceSoLaterMarksAreIgnored() {
        let tracer = LaunchTracer(processStart: Date())

        tracer.mark(.main)
        tracer.mark(.firstFramePresented)
        tracer.mark(.intentsRouted)

        XCTAssertEqual(tracer.recordedMarks.map(\.stage), [.main, .firstFramePresented])
    }

    func testTheReportNamesEveryStageItRecorded() {
        let tracer = LaunchTracer(processStart: Date())

        tracer.mark(.main)
        tracer.mark(.menuInstalled)

        let report = tracer.report()
        XCTAssertTrue(report.contains("main"))
        XCTAssertTrue(report.contains("menuInstalled"))
        XCTAssertFalse(report.contains("intentsRouted"))
    }

    func testProcessStartIsInThePast() {
        XCTAssertLessThan(LaunchTracer.processStartDate(), Date())
    }
}
