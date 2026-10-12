import Foundation
@testable import TablePro
import Testing

/// The regression these exist for: every Sparkle update control read `false` on a fresh install,
/// because `SUEnableAutomaticChecks` was declared nowhere. Sparkle resolves a key as user defaults
/// first and Info.plist second, so an undeclared key is `NO`, `allowsAutomaticUpdates` is then `NO`
/// too, and `setAutomaticallyDownloadsUpdates` returns without writing. `SUAutomaticallyUpdate` was
/// `true` in Info.plist and `false` everywhere it mattered.
struct SparkleUpdatePreferencesTests {
    /// The unit-test bundle is hosted by the app, so the process's main bundle is the app bundle.
    /// A runner that ever stopped hosting would fail `everyRequiredKeyIsDeclared` rather than pass
    /// it quietly, which is the failure direction to want.
    private var appBundle: Bundle { Bundle.main }

    @Test("Every Sparkle key the app depends on carries a default in Info.plist")
    func everyRequiredKeyIsDeclared() {
        let missing = SparkleUpdatePreferences.keysMissingDefaults(in: appBundle)
        #expect(missing.isEmpty, "Info.plist declares no default for \(missing.joined(separator: ", "))")
    }

    @Test("A key the user can change has a default to go back to")
    func everySettableKeyHasADeclaredDefault() {
        for key in SparkleUpdatePreferences.userSettableKeys {
            #expect(
                SparkleUpdatePreferences.requiredInfoPlistKeys.contains(key),
                "\(key) is resettable but has no declared default, so resetting it re-arms Sparkle's permission prompt"
            )
        }
    }

    @Test("The shipped defaults are checks on, installs on, daily")
    func shippedDefaults() throws {
        #expect(appBundle.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == true)
        #expect(appBundle.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool == true)

        let interval = try #require(appBundle.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int)
        #expect(interval == 86_400)
        #expect(interval >= 3_600, "Sparkle clamps the scheduled check to a one-hour floor")
        #expect(
            interval < 604_800,
            "an interval at or above Sparkle's 604800 impatient default leaves a downloaded fix waiting longer than the reminder that chases it"
        )
    }

    @Test("The feed is fetched over HTTPS and its signing key is declared")
    func feedIsSigned() throws {
        let feed = try #require(appBundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        #expect(feed.hasPrefix("https://"))

        let key = try #require(appBundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        #expect(!key.isEmpty)
        #expect(Data(base64Encoded: key)?.count == 32, "an EdDSA public key is 32 bytes")
    }

    @Test("Reset removes every user-settable key and nothing else")
    func resetRemovesOnlyTheKeysSparkleOwns() throws {
        let suite = "com.TablePro.tests.sparkle-reset"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

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

    /// The only signal a deferred update leaves. Sparkle's standard driver shows nothing when
    /// `standardUserDriverShouldHandleShowingScheduledUpdate` returns false, so a title that did not
    /// change would mean the update was never announced at all.
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
        let suite = "com.TablePro.tests.sparkle-reset-empty"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        SparkleUpdatePreferences.reset(in: defaults)
        SparkleUpdatePreferences.reset(in: defaults)

        for key in SparkleUpdatePreferences.userSettableKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
    }
}
