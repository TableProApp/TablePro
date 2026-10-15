import Foundation

enum ScratchDefaults {
    // A suite named by a path keeps its plist in the temporary directory; a bare name leaves one in ~/Library/Preferences.
    static func suiteName() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("com.TablePro.tests.\(UUID().uuidString)", isDirectory: false)
            .path
    }

    static func make() -> UserDefaults? {
        UserDefaults(suiteName: suiteName())
    }
}
