import Foundation
import Testing

@testable import TablePro

struct DamengConnectTimeoutTests {
    @Test("Cancellation wins even when it arrives before native connect starts")
    func cancellationBeforeArmWins() async {
        let gate = DamengConnectGate()
        var abandoned = false
        gate.fail(CancellationError()) { abandoned = true }

        do {
            try await withCheckedThrowingContinuation {
                gate.arm($0)
            }
            Issue.record("The cancelled attempt was adopted")
        } catch is CancellationError {
            #expect(abandoned)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Native connect can return after the host gate has already resumed the caller. The
        // late delivery must be ignored rather than resuming the continuation a second time.
        gate.finish(with: .success(()))
    }

    @Test("Initial connect uses the remaining budget and reconnect uses the full setting")
    func remainingAndReconnectBudgets() {
        let timeout = DamengConnectTimeout(additionalFields: [
            "connectTimeoutMilliseconds": "4321",
            "connectTimeoutSeconds": "30"
        ])

        #expect(timeout.milliseconds == 4_321)
        #expect(timeout.reconnectMilliseconds == 30_000)
    }

    @Test("Missing and invalid values keep the default while valid extremes clamp")
    func fallbacksAndClamps() {
        #expect(DamengConnectTimeout(additionalFields: [:]).milliseconds == 30_000)
        #expect(
            DamengConnectTimeout(additionalFields: ["connectTimeoutMilliseconds": "bad"]).milliseconds == 30_000
        )
        #expect(DamengConnectTimeout(additionalFields: ["connectTimeoutSeconds": "0"]).milliseconds == 1)
        #expect(
            DamengConnectTimeout(additionalFields: ["connectTimeoutSeconds": String(Int.max)]).milliseconds
                == 3_600_000
        )
        #expect(
            DamengConnectTimeout(additionalFields: ["connectTimeoutSeconds": String(Int64.min)]).milliseconds == 1
        )
    }
}
