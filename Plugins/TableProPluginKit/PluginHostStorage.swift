//
//  PluginHostStorage.swift
//  TableProPluginKit
//

import Foundation

/// Lives in PluginKit so `PluginSettingsStorage` and the app derive the same sandbox suite.
public enum PluginHostStorage {
    public static let sandboxVariable = "TABLEPRO_UI_TEST_SANDBOX"

    /// The prefix of every sandbox suite; `scripts/clean-test-residue.sh` finds them by it.
    public static let sandboxSuiteName = "com.TablePro.uitest"

    /// One suite per sandbox path, so concurrent runs from other plans or checkouts never share one.
    public static func suiteName(forSandboxAt path: String) -> String {
        "\(sandboxSuiteName).\(stableDigest(of: URL(fileURLWithPath: path).path))"
    }

    public static func resolveDefaults() -> UserDefaults {
        let path = ProcessInfo.processInfo.environment[sandboxVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty,
              let sandboxed = UserDefaults(suiteName: suiteName(forSandboxAt: path))
        else { return .standard }
        return sandboxed
    }

    /// FNV-1a, because `Hasher` is seeded per process and the app, its plugins and the next run must agree.
    private static func stableDigest(of text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
