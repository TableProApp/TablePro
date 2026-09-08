//
//  SplitViewAutosaveName.swift
//  TablePro
//

import Foundation

/// The names AppKit files persisted window and pane geometry under.
///
/// AppKit writes an autosave record into the app process's own standard defaults domain. The UI
/// test sandbox does not reach that: it redirects `applicationSupportRoot` and hands out its own
/// `UserDefaults(suiteName:)`, and these records land in neither. So a sidebar width, a divider
/// position, a collapsed pane or a window frame set by one UI test case is inherited by every case
/// that runs after it in the same shard, on the real machine's defaults.
///
/// That is not theoretical. CI shards the UI suite by list position (`runnable[index::count]` in
/// `scripts/ci/list_tests.py`), so adding two unrelated cases re-deals every later case onto a
/// different runner. A query history case that had been passing moved shards, woke up with another
/// case's geometry, and its drawer laid out taller than the 1024x768 runner's window: the detail
/// pane ran from y=545 to y=712 against a window bottom edge at y=705, so Copy, Run in New Tab and
/// Load in Editor all straddled the edge and the click on Load in Editor did nothing. The failure
/// looked like a broken feature and was a leaked preference.
///
/// Namespacing the record per sandbox gives every case the default layout it expects. Production
/// keeps the bare name: versioning those would throw away every width, divider and frame a real
/// user has saved.
internal enum SplitViewAutosaveName {
    /// Never version this. `NSSplitView` clamps a restored frame against the current minimums, so a
    /// pane simply widens to fit; bumping the key instead discards every width and collapse state
    /// the user has and leaves the old keys orphaned.
    internal static let base = "com.TablePro.mainSplit"

    /// - Parameter sandboxIdentifier: something unique to one test case. The sandbox root's last
    ///   path component is a fresh UUID per case, which is exactly that.
    internal static func resolved(isIsolated: Bool, sandboxIdentifier: String?) -> String {
        resolved(base, isIsolated: isIsolated, sandboxIdentifier: sandboxIdentifier)
    }

    /// The general form. Every autosave name in the app goes through this, because they all land in
    /// the same unisolated defaults and leak the same way.
    internal static func resolved(
        _ name: String,
        isIsolated: Bool,
        sandboxIdentifier: String?
    ) -> String {
        guard isIsolated, let sandboxIdentifier, !sandboxIdentifier.isEmpty else { return name }
        return "\(name).\(sandboxIdentifier)"
    }

    /// What a call site uses. Reads the running environment so a caller cannot forget the rule.
    @MainActor
    internal static func current(_ name: String) -> String {
        let environment = AppStorageEnvironment.shared
        return resolved(
            name,
            isIsolated: environment.isIsolated,
            sandboxIdentifier: environment.applicationSupportRoot.lastPathComponent
        )
    }
}
