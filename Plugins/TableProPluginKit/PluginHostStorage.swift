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

    /// One fixed domain for every sandboxed run, not one per run. A defaults domain is a file in
    /// the user's preferences directory and `cfprefsd` writes it out after the process that owns it
    /// has already exited, so neither the app nor the test can reliably delete its own: one session
    /// left 194 of them behind that way. A single name means at most one file exists, and the test
    /// harness empties the domain before each test, which is what actually isolates them. The files
    /// inside the sandbox directory stay per-run.
    public static let sandboxSuiteName = "com.TablePro.uitest"

    public static func suiteName(forSandboxAt path: String) -> String {
        sandboxSuiteName
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
