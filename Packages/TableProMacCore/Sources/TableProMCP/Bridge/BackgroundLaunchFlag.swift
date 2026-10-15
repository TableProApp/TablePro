import Foundation

// Set by the bridge when it launches the app for a client; `open -g` passes its environment through.
public enum BackgroundLaunchFlag {
    public static let variable = "TABLEPRO_BACKGROUND_LAUNCH"
    public static let value = "1"

    public static func isSet(in environment: [String: String]) -> Bool {
        environment[variable] == value
    }
}
