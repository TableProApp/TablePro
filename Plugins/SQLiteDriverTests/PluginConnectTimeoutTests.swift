import Foundation
import Testing

@testable import TablePro

struct PluginConnectTimeoutTests {
    @Test("Millisecond timeout takes precedence over seconds")
    func millisecondsTakePrecedence() {
        let fields = [
            "connectTimeoutMilliseconds": "1250",
            "connectTimeoutSeconds": "9"
        ]

        #expect(PluginConnectTimeout.milliseconds(in: fields, default: 60_000) == 1_250)
    }

    @Test("Seconds are converted when milliseconds are absent")
    func secondsFallback() {
        let fields = ["connectTimeoutSeconds": "2.5"]

        #expect(PluginConnectTimeout.milliseconds(in: fields, default: 60_000) == 2_500)
        #expect(PluginConnectTimeout.seconds(in: fields, default: 60) == 2.5)
    }

    @Test("Invalid milliseconds fall back to valid seconds")
    func invalidMillisecondsFallBackToSeconds() {
        let invalidMilliseconds = [
            "connectTimeoutMilliseconds": "invalid",
            "connectTimeoutSeconds": "2"
        ]

        #expect(PluginConnectTimeout.milliseconds(in: invalidMilliseconds, default: 60_000) == 2_000)
    }

    @Test("Missing or invalid timeout values keep the driver default")
    func invalidValuesKeepDefault() {
        let invalidSeconds = ["connectTimeoutSeconds": "NaN"]

        #expect(PluginConnectTimeout.milliseconds(in: invalidSeconds, default: 120_000) == 120_000)
        #expect(PluginConnectTimeout.milliseconds(in: [:], default: 30_000) == 30_000)
    }

    @Test("Finite configured values are clamped to the supported bounds")
    func clampsConfiguredValues() {
        #expect(
            PluginConnectTimeout.milliseconds(
                in: ["connectTimeoutMilliseconds": "0"],
                default: 60_000
            ) == 1
        )
        #expect(
            PluginConnectTimeout.milliseconds(
                in: ["connectTimeoutSeconds": "-30"],
                default: 60_000
            ) == 1
        )
        #expect(
            PluginConnectTimeout.milliseconds(
                in: ["connectTimeoutSeconds": "999999"],
                default: 60_000
            ) == PluginConnectTimeout.maximumMilliseconds
        )
    }

    @Test("Fractional milliseconds truncate after seconds conversion")
    func truncatesFractionalMilliseconds() {
        #expect(
            PluginConnectTimeout.milliseconds(
                in: ["connectTimeoutSeconds": "1.2349"],
                default: 60_000
            ) == 1_234
        )
    }

    @Test("Connect deadline reports the remaining monotonic budget")
    func remainingDeadlineBudget() {
        let start = ContinuousClock.now
        let deadline = PluginConnectDeadline(milliseconds: 2_500, now: start)

        #expect(deadline.remainingMilliseconds(at: start) == 2_500)
        #expect(deadline.remainingMilliseconds(at: start.advanced(by: .milliseconds(1_200))) == 1_300)
        #expect(deadline.remainingMilliseconds(at: start.advanced(by: .seconds(3))) == 1)
    }

    @Test("AWS credential phases keep the original monotonic deadline")
    func awsSessionBudgetKeepsOriginalDeadline() {
        let start = ContinuousClock.now
        let deadline = PluginConnectDeadline(milliseconds: 2_500, now: start)
        let budget = PluginAWSConnectSessionBudget(
            deadline: deadline,
            now: start.advanced(by: .milliseconds(500)),
            systemUptime: 100
        )

        #expect(budget.remainingSeconds == 2)
        #expect(budget.expiresAtUptime == 102)

        let laterPhase = PluginAWSConnectSessionBudget(expiresAtUptime: budget.expiresAtUptime, now: 101.25)
        #expect(laterPhase?.remainingSeconds == 0.75)
        #expect(PluginAWSConnectSessionBudget(expiresAtUptime: budget.expiresAtUptime, now: 102) == nil)
    }

    @Test("Connect phase restores the driver's normal request timeout")
    func connectPhaseRestoresFallback() {
        let phase = PluginConnectTimeoutPhase(
            deadline: PluginConnectDeadline(milliseconds: 2_500)
        )

        #expect(phase.remainingSeconds(or: 90) <= 2.5)
        #expect(phase.remainingSeconds(or: 90) > 2)

        phase.finish()
        #expect(phase.remainingSeconds(or: 90) == 90)
    }
}
