//
//  PluginHostStorage.swift
//  TableProPluginKit
//

import Foundation

/// Where the host app and everything loaded into it keep preferences. A UI test names a throwaway
/// directory in `TABLEPRO_UI_TEST_SANDBOX`, and every writer resolves its defaults domain from here
/// so none of them can reach the real one.
///
/// This lives in PluginKit rather than in the app because `PluginSettingsStorage` is here and cannot
/// see the app module, and one derivation of the suite name is the only way the two agree. Adding a
/// type is additive, so it needs no PluginKit version bump.
public enum PluginHostStorage {
    public static let sandboxVariable = "TABLEPRO_UI_TEST_SANDBOX"

    /// The sandbox path names the suite, so a run gets its own domain and two runs in different
    /// directories never share one.
    public static func suiteName(forSandboxAt path: String) -> String {
        "com.TablePro.uitest.\(URL(fileURLWithPath: path).lastPathComponent)"
    }

    public static func resolveDefaults() -> UserDefaults {
        let path = ProcessInfo.processInfo.environment[sandboxVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty,
              let sandboxed = UserDefaults(suiteName: suiteName(forSandboxAt: path))
        else { return .standard }
        return sandboxed
    }
}
