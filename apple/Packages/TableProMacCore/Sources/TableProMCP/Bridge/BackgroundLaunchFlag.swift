import Foundation

// Set in the launch environment when a helper starts the app for a client.
public enum BackgroundLaunchFlag {
    public static let variable = "TABLEPRO_BACKGROUND_LAUNCH"
    public static let value = "1"

    public static func isSet(in environment: [String: String]) -> Bool {
        environment[variable] == value
    }
}
