import TableProPluginKit
@testable import TablePro
import Testing

@Suite("IntegrationStatusIndicator")
struct IntegrationStatusIndicatorTests {
    @Test("Running status exposes a localized accessibility label")
    func runningLabel() {
        let indicator = IntegrationStatusIndicator(status: .running, label: "Running on port 23000")
        let description = indicator.accessibilityDescription
        #expect(description.contains("running"))
        #expect(description.contains("Running on port 23000"))
    }

    @Test("Stopped status mentions stopped in accessibility label")
    func stoppedLabel() {
        let indicator = IntegrationStatusIndicator(status: .stopped, label: nil)
        #expect(indicator.accessibilityDescription.contains("stopped"))
    }

    @Test("Failed status mentions failed in accessibility label")
    func failedLabel() {
        let indicator = IntegrationStatusIndicator(status: .failed, label: nil)
        #expect(indicator.accessibilityDescription.contains("failed"))
    }

    @Test("Expired status mentions expired in accessibility label")
    func expiredLabel() {
        let indicator = IntegrationStatusIndicator(status: .expired, label: nil)
        #expect(indicator.accessibilityDescription.contains("expired"))
    }

    @Test("Revoked status mentions revoked in accessibility label")
    func revokedLabel() {
        let indicator = IntegrationStatusIndicator(status: .revoked, label: nil)
        #expect(indicator.accessibilityDescription.contains("revoked"))
    }

    @Test("Active status mentions active in accessibility label")
    func activeLabel() {
        let indicator = IntegrationStatusIndicator(status: .active, label: nil)
        #expect(indicator.accessibilityDescription.contains("active"))
    }

    @Test("Warning, success, error, starting all expose distinct labels")
    func remainingLabels() {
        #expect(IntegrationStatusIndicator(status: .warning, label: nil).accessibilityDescription.contains("warning"))
        #expect(IntegrationStatusIndicator(status: .success, label: nil).accessibilityDescription.contains("success"))
        #expect(IntegrationStatusIndicator(status: .error, label: nil).accessibilityDescription.contains("error"))
        #expect(IntegrationStatusIndicator(status: .starting, label: nil).accessibilityDescription.contains("starting"))
    }
}
