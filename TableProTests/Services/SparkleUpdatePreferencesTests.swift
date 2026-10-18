import Foundation
@testable import TablePro
import Testing

struct SparkleUpdatePreferencesTests {
    // The unit tests are hosted by the app, so the main bundle is TablePro.app and its built Info.plist.
    private var appBundle: Bundle { Bundle.main }

    // An undeclared key resolves to NO in Sparkle (#2865). `SUScheduledImpatientCheckInterval` keeps Sparkle's default.
    private static let requiredInfoPlistKeys = [
        "SUFeedURL",
        "SUPublicEDKey",
        "SURequireSignedFeed",
        "SUVerifyUpdateBeforeExtraction",
        "SUEnableAutomaticChecks",
        "SUScheduledCheckInterval",
        "SUAutomaticallyUpdate",
    ]

    @Test("Every Sparkle key the app depends on carries a default in Info.plist")
    func everyRequiredKeyIsDeclared() {
        let missing = Self.requiredInfoPlistKeys.filter { appBundle.object(forInfoDictionaryKey: $0) == nil }
        #expect(missing.isEmpty, "Info.plist declares no default for \(missing.joined(separator: ", "))")
    }

    @Test("A key the user can change has a default to go back to")
    func everySettableKeyHasADeclaredDefault() {
        for key in SparkleUpdatePreferences.userSettableKeys {
            #expect(appBundle.object(forInfoDictionaryKey: key) != nil, "\(key) is resettable but Info.plist declares no default")
        }
    }

    @Test("The shipped defaults are checks on, installs on, daily")
    func shippedDefaults() {
        #expect(appBundle.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == true)
        #expect(appBundle.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool == true)
        #expect(appBundle.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int == 86_400)
    }

    @Test("The feed comes from updates.tablepro.app, signed, and every archive is verified before extraction")
    func feedIsSigned() throws {
        #expect(appBundle.object(forInfoDictionaryKey: "SUFeedURL") as? String == "https://updates.tablepro.app/appcast.xml")
        #expect(appBundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true)
        #expect(appBundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true)

        let key = try #require(appBundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        #expect(Data(base64Encoded: key)?.count == 32, "an EdDSA public key is 32 bytes")
    }

    @Test("Reset removes every user-settable key and nothing else")
    func resetRemovesOnlyTheKeysSparkleOwns() throws {
        let suite = try EphemeralDefaults()
        let defaults = suite.defaults

        for key in SparkleUpdatePreferences.userSettableKeys {
            defaults.set(true, forKey: key)
        }
        defaults.set("keep me", forKey: "SUFeedURL")

        SparkleUpdatePreferences.reset(in: defaults)

        for key in SparkleUpdatePreferences.userSettableKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) survived the reset")
        }
        #expect(defaults.string(forKey: "SUFeedURL") == "keep me", "reset cleared a key Sparkle does not let the user set")
    }

    @Test("A deferred update renames the control, and nothing else does")
    @MainActor
    func deferredUpdateRenamesTheControl() {
        let idle = SoftwareUpdater.checkForUpdatesTitle(hasPendingUpdate: false)
        let pending = SoftwareUpdater.checkForUpdatesTitle(hasPendingUpdate: true)

        #expect(idle != pending)
        #expect(idle.hasSuffix("…"), "the title opens a dialog, so it keeps its ellipsis")
        #expect(pending.hasSuffix("…"))
    }

    @Test("Reset on a domain that never held the keys is a no-op")
    func resetIsIdempotent() throws {
        let suite = try EphemeralDefaults()
        let defaults = suite.defaults

        SparkleUpdatePreferences.reset(in: defaults)
        SparkleUpdatePreferences.reset(in: defaults)

        for key in SparkleUpdatePreferences.userSettableKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
    }
}
