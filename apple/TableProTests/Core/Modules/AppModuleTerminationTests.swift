import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
private final class StopRecord {
    var didStop = false
}

@MainActor
struct AppModuleTerminationTests {
    @Test("Quitting waits for a stop that finishes in time")
    func stopInTimeIsAwaited() async {
        let clock = ManualClock()
        let record = StopRecord()

        let finished = await AppModuleTermination.runCapped(at: AppModuleTermination.stopLimit, clock: clock) {
            record.didStop = true
        }

        #expect(finished)
        #expect(record.didStop)
    }

    @Test("A stop that never returns holds the quit no longer than the limit")
    func stuckStopIsAbandonedAtTheLimit() async {
        let clock = ManualClock()
        let stuck = AsyncGate()
        let run = Task { @MainActor in
            await AppModuleTermination.runCapped(at: .seconds(5), clock: clock) {
                await stuck.wait()
            }
        }

        await stuck.arrived(1)
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(5))

        #expect(await run.value == false)
        await stuck.open()
    }

    @Test("The quit limit is five seconds")
    func limitIsFiveSeconds() {
        #expect(AppModuleTermination.stopLimit == .seconds(5))
    }
}
