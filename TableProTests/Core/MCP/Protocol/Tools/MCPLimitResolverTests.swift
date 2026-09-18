import Foundation
@testable import TablePro
import Testing

@Suite("MCPLimitResolver")
struct MCPLimitResolverTests {
    private func settings(
        defaultRowLimit: Int = 500,
        maxRowLimit: Int = 10_000,
        queryTimeoutSeconds: Int = 30
    ) -> MCPSettings {
        MCPSettings(
            defaultRowLimit: defaultRowLimit,
            maxRowLimit: maxRowLimit,
            queryTimeoutSeconds: queryTimeoutSeconds
        )
    }

    @Test("Omitted max_rows falls back to the configured default row limit")
    func omittedRequestUsesDefault() {
        let resolved = MCPLimitResolver.resolveMaxRows(requested: nil, settings: settings(defaultRowLimit: 750))
        #expect(resolved == 750)
    }

    @Test("Requested max_rows above the configured maximum is clamped to it")
    func requestAboveMaximumIsClamped() {
        let resolved = MCPLimitResolver.resolveMaxRows(requested: 999_999, settings: settings(maxRowLimit: 10_000))
        #expect(resolved == 10_000)
    }

    @Test("Requested max_rows within range is honoured")
    func requestWithinRangeIsHonoured() {
        let resolved = MCPLimitResolver.resolveMaxRows(requested: 9_000, settings: settings(maxRowLimit: 10_000))
        #expect(resolved == 9_000)
    }

    @Test("Raising the configured maximum raises the effective ceiling")
    func raisedMaximumRaisesCeiling() {
        let resolved = MCPLimitResolver.resolveMaxRows(requested: 50_000, settings: settings(maxRowLimit: 100_000))
        #expect(resolved == 50_000)
    }

    @Test("A default above the configured maximum is capped by the maximum")
    func defaultAboveMaximumIsCapped() {
        let resolved = MCPLimitResolver.resolveMaxRows(
            requested: nil,
            settings: settings(defaultRowLimit: 50_000, maxRowLimit: 1_000)
        )
        #expect(resolved == 1_000)
    }

    @Test("Zero and negative requests are raised to one instead of trapping")
    func nonPositiveRequestIsRaised() {
        #expect(MCPLimitResolver.resolveMaxRows(requested: 0, settings: settings()) == 1)
        #expect(MCPLimitResolver.resolveMaxRows(requested: -5, settings: settings()) == 1)
    }

    @Test("A zero maximum row limit resolves without trapping")
    func zeroMaximumDoesNotTrap() {
        let resolved = MCPLimitResolver.resolveMaxRows(requested: 100, settings: settings(maxRowLimit: 0))
        #expect(resolved == 1)
    }

    @Test("A negative maximum row limit resolves without trapping")
    func negativeMaximumDoesNotTrap() {
        let resolved = MCPLimitResolver.resolveMaxRows(requested: nil, settings: settings(maxRowLimit: -20))
        #expect(resolved == 1)
    }

    @Test("Omitted timeout falls back to the configured query timeout")
    func omittedTimeoutUsesConfigured() {
        let resolved = MCPLimitResolver.resolveTimeoutSeconds(
            requested: nil,
            settings: settings(queryTimeoutSeconds: 45)
        )
        #expect(resolved == 45)
    }

    @Test("Requested timeout is clamped to the protocol ceiling of 300 seconds")
    func requestedTimeoutIsClamped() {
        #expect(MCPLimitResolver.resolveTimeoutSeconds(requested: 5_000, settings: settings()) == 300)
        #expect(MCPLimitResolver.resolveTimeoutSeconds(requested: 0, settings: settings()) == 1)
    }

    @Test("A zero configured timeout resolves to the minimum instead of disabling the timeout")
    func zeroConfiguredTimeoutIsRaised() {
        let resolved = MCPLimitResolver.resolveTimeoutSeconds(
            requested: nil,
            settings: settings(queryTimeoutSeconds: 0)
        )
        #expect(resolved == 1)
    }
}
