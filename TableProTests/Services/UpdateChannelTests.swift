import Foundation
@testable import TablePro
import Testing

struct UpdateChannelTests {
    @Test("An unset preference asks Sparkle for the default channel only")
    func unsetAllowsNoExtraChannel() throws {
        let suite = try EphemeralDefaults()

        #expect(UpdateChannel.selected(in: suite.defaults) == .stable)
        #expect(UpdateChannel.selected(in: suite.defaults).sparkleChannels == [])
    }

    @Test("Turning beta updates on adds the beta channel")
    func onAllowsBeta() throws {
        let suite = try EphemeralDefaults()

        UpdateChannel.select(.beta, in: suite.defaults)

        #expect(suite.defaults.bool(forKey: PreferenceKeys.receivesBetaUpdates.name))
        #expect(UpdateChannel.selected(in: suite.defaults).sparkleChannels == ["beta"])
    }

    @Test("Turning beta updates off goes back to the default channel")
    func offAllowsNoExtraChannel() throws {
        let suite = try EphemeralDefaults()

        UpdateChannel.select(.beta, in: suite.defaults)
        UpdateChannel.select(.stable, in: suite.defaults)

        #expect(UpdateChannel.selected(in: suite.defaults).sparkleChannels == [])
    }

    @Test("Reset removes the key")
    func resetRemovesTheKey() throws {
        let suite = try EphemeralDefaults()

        UpdateChannel.select(.beta, in: suite.defaults)
        UpdateChannel.clearSelection(in: suite.defaults)

        #expect(suite.defaults.object(forKey: PreferenceKeys.receivesBetaUpdates.name) == nil)
        #expect(UpdateChannel.selected(in: suite.defaults) == .stable)
    }

    @Test("Stable takes only stable releases")
    func stableAcceptsStableOnly() {
        #expect(UpdateChannel.stable.accepts("stable"))
        #expect(!UpdateChannel.stable.accepts("beta"))
        #expect(!UpdateChannel.stable.accepts("nightly"))
        #expect(!UpdateChannel.stable.accepts(""))
    }

    @Test("Beta takes stable and beta releases")
    func betaAcceptsStableAndBeta() {
        #expect(UpdateChannel.beta.accepts("stable"))
        #expect(UpdateChannel.beta.accepts("beta"))
        #expect(!UpdateChannel.beta.accepts("nightly"))
        #expect(!UpdateChannel.beta.accepts("Beta"))
    }
}
