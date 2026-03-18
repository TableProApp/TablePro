import Foundation

public enum NavigationModel: String, Sendable {
    case standard    // open new tab on table click
    case inPlace     // replace current tab content (e.g. Redis database switching)
}
