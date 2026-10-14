import Foundation

/// Apple documents `autosaveName` and nothing else, so this spelling is a transcription that
/// `SplitViewAutosaveKeyTests` checks against a real `NSSplitView`.
public enum SplitViewAutosaveKey {
    public static let prefix = "NSSplitView Subview Frames "

    public static func key(forAutosaveName name: String) -> String {
        prefix + name
    }
}
