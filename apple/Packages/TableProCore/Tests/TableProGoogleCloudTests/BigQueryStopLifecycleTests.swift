import Foundation
@testable import TableProGoogleCloud
import Testing

struct BigQueryStopLifecycleTests {
    typealias Stage = BigQueryStopLifecycle.Stage
    typealias Event = BigQueryStopLifecycle.Event
    typealias Effect = BigQueryStopLifecycle.Effect

    private struct Transition {
        let from: Stage
        let event: Event
        let next: Stage
        let effects: [Effect]
    }

    static let stages: [Stage] = [
        .notStarted,
        .cancelledBeforeStart,
        .running,
        .stopped(callerReleased: false),
        .stopped(callerReleased: true),
        .answered,
        .failed,
        .answeredAfterStop,
        .failedAfterStop
    ]

    private static let transitions: [Transition] = [
        Transition(from: .notStarted, event: .start, next: .running, effects: [.launchRequest]),
        Transition(from: .notStarted, event: .stop, next: .cancelledBeforeStart, effects: []),
        Transition(from: .cancelledBeforeStart, event: .start, next: .cancelledBeforeStart, effects: [
            .releaseCaller(.cancelled)
        ]),
        Transition(from: .running, event: .answer, next: .answered, effects: [.releaseCaller(.answer)]),
        Transition(from: .running, event: .failure, next: .failed, effects: [.releaseCaller(.error)]),
        Transition(from: .running, event: .stop, next: .stopped(callerReleased: false), effects: [.armTimer]),
        Transition(from: .stopped(callerReleased: false), event: .answer, next: .answeredAfterStop, effects: [
            .releaseCaller(.cancelled), .cancelTimer, .handOverAnswer
        ]),
        Transition(from: .stopped(callerReleased: false), event: .failure, next: .failedAfterStop, effects: [
            .releaseCaller(.cancelled), .cancelTimer
        ]),
        Transition(
            from: .stopped(callerReleased: false),
            event: .graceElapsed,
            next: .stopped(callerReleased: true),
            effects: [.releaseCaller(.cancelled)]
        ),
        Transition(
            from: .stopped(callerReleased: false),
            event: .limitElapsed,
            next: .stopped(callerReleased: true),
            effects: [.releaseCaller(.cancelled), .cancelRequest]
        ),
        Transition(from: .stopped(callerReleased: true), event: .answer, next: .answeredAfterStop, effects: [
            .cancelTimer, .handOverAnswer
        ]),
        Transition(from: .stopped(callerReleased: true), event: .failure, next: .failedAfterStop, effects: [
            .cancelTimer
        ]),
        Transition(
            from: .stopped(callerReleased: true),
            event: .graceElapsed,
            next: .stopped(callerReleased: true),
            effects: []
        ),
        Transition(
            from: .stopped(callerReleased: true),
            event: .limitElapsed,
            next: .stopped(callerReleased: true),
            effects: [.cancelRequest]
        )
    ]

    @Test("Each stage moves on each event as the lifecycle table says, and nowhere else",
          arguments: BigQueryStopLifecycleTests.stages, BigQueryStopLifecycle.Event.allCases)
    func everyStageAndEvent(stage: Stage, event: Event) {
        let expected = Self.transitions.first { $0.from == stage && $0.event == event }
        var lifecycle = BigQueryStopLifecycle(stage: stage)

        let effects = lifecycle.handle(event)

        #expect(lifecycle.stage == (expected?.next ?? stage))
        #expect(effects == (expected?.effects ?? []))
    }

    @Test("A request reads as stopped from Stop on, and never before", arguments: BigQueryStopLifecycleTests.stages)
    func stoppedFromStopOn(stage: Stage) {
        let afterStop: [Stage] = [
            .cancelledBeforeStart,
            .stopped(callerReleased: false),
            .stopped(callerReleased: true),
            .answeredAfterStop,
            .failedAfterStop
        ]
        #expect(BigQueryStopLifecycle(stage: stage).isStopped == afterStop.contains(stage))
    }

    @Test("Each caller is released once, whatever order the events come in")
    func callerReleasedOnce() {
        for order in [
            [Event.start, .answer, .stop, .graceElapsed, .limitElapsed],
            [.start, .stop, .graceElapsed, .answer, .limitElapsed],
            [.start, .stop, .answer, .graceElapsed, .limitElapsed],
            [.start, .stop, .graceElapsed, .limitElapsed, .failure],
            [.stop, .start, .answer, .graceElapsed]
        ] {
            var lifecycle = BigQueryStopLifecycle()
            let releases = order.flatMap { lifecycle.handle($0) }.filter {
                if case .releaseCaller = $0 { return true }
                return false
            }
            #expect(releases.count == 1, "\(order)")
        }
    }
}
