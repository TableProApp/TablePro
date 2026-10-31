import Foundation

internal struct WhatsNewNotice {
    let bundle: Bundle
    let defaults: UserDefaults

    func recordLaunch() -> Bool {
        // A build without notes records nothing, so a Debug run never marks a release as seen.
        guard WhatsNewContent.load(from: bundle) != nil else { return false }
        // Sparkle orders releases by CFBundleVersion, which RELEASING.md numbers so a beta sorts below its stable.
        let current = bundle.buildNumber
        let key = PreferenceKeys.lastSeenAppBuild.name
        guard let seen = defaults.object(forKey: key) as? Int else {
            defaults.set(current, forKey: key)
            // Every build that recorded only the version is older than this one.
            let legacy = defaults.string(forKey: PreferenceKeys.lastSeenAppVersion.name)
            return legacy.map { $0 != bundle.appVersion } ?? false
        }
        // An older build writes nothing, so going back to the newer one does not offer its notes again.
        guard seen < current else { return false }
        defaults.set(current, forKey: key)
        return true
    }
}
