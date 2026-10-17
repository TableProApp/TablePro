import Foundation

internal extension Bundle {
    var appVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var buildNumber: Int {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) } ?? 0
    }

    var isPrerelease: Bool {
        appVersion.contains("-")
    }

    var displayVersion: String {
        "\(appVersion) (\(buildNumber))"
    }
}
