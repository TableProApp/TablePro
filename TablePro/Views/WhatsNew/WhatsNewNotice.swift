import Foundation

internal struct WhatsNewNotice {
    let bundle: Bundle
    let defaults: UserDefaults

    func recordLaunch() -> Bool {
        // A build without notes records nothing, so a Debug run never marks a release as seen.
        guard WhatsNewContent.load(from: bundle) != nil else { return false }
        let key = PreferenceKeys.lastSeenAppVersion.name
        let current = bundle.appVersion
        let previous = defaults.string(forKey: key)
        defaults.set(current, forKey: key)
        return previous.map { $0 != current } ?? false
    }
}
