//
//  SplitViewAutosaveSweep.swift
//  TablePro
//

import AppKit
import Foundation
import os

/// What one `NSSplitView` autosave record describes.
///
/// `NSSplitView` files a record under `"NSSplitView Subview Frames <autosaveName>"`, one key per
/// name, in the app's own standard defaults domain. Apple documents neither the spelling nor any way
/// to forget one: `autosaveName` is the whole API, and where `NSTableView` documents that setting it
/// to nil clears the saved data, `NSSplitView` says nothing. `removeObject` is the only route.
internal enum SplitViewAutosaveRecord: Equatable {
    /// A record of the retired `QuerySplit-<connectionId>-<tabId>` family. Nothing writes or reads
    /// that name any more, so no connection and no tab can make one of these live again.
    case retiredPerTabQuerySplit
    /// Every other name, which this sweep leaves alone. A name it does not recognise is one whose
    /// lifetime it cannot reason about, and guessing costs a reader their saved layout.
    case unrecognised

    /// Undocumented by Apple, so `SplitViewAutosaveSweepTests` derives it from a real `NSSplitView`
    /// rather than trusting this transcription.
    internal static let keyPrefix = "NSSplitView Subview Frames "

    private static let uuidLength = 36

    /// Parses a defaults key, or returns nil when the key is not an autosave record at all.
    internal static func parse(key: String) -> SplitViewAutosaveRecord? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        let name = String(key.dropFirst(keyPrefix.count))
        guard let rest = name.dropPrefixIfPresent(SplitViewAutosaveName.querySplitPrefix) else {
            return .unrecognised
        }
        return isRetiredPerTabRemainder(rest) ? .retiredPerTabQuerySplit : .unrecognised
    }

    /// Two UUIDs joined by a hyphen, which is also the separator inside each of them, so the shape
    /// is checked by length rather than by searching for the separator. A name carrying a UI test's
    /// sandbox suffix is longer than this and stays `unrecognised`, which is what keeps one test
    /// case's record out of a rule written for the real domain.
    private static func isRetiredPerTabRemainder(_ text: String) -> Bool {
        guard text.count == uuidLength * 2 + 1 else { return false }
        let boundary = text.index(text.startIndex, offsetBy: uuidLength)
        guard text[boundary] == "-" else { return false }
        return UUID(uuidString: String(text[text.startIndex ..< boundary])) != nil
            && UUID(uuidString: String(text[text.index(after: boundary)...])) != nil
    }
}

/// Removes the records of the retired per-tab query split, and nothing else.
///
/// That name minted one permanent record per query tab ever opened, because `QueryTab.id` persists
/// across launches and is never reused. Measured on one developer machine: 795 of them in a
/// 12,476-key, 1.9 MB `com.TablePro.plist`, which `UserDefaults` parses in full on first access
/// during launch, linearly at 0.93us per key.
///
/// Deliberately no liveness set. Judging a record by whether its connection still exists needs an
/// answer to "which connections exist" that `ConnectionStorage` cannot give: a linked-folder or
/// team-library connection is built and opened transiently and never saved, so it would read as
/// deleted on every launch and lose its geometry every time. The retired family needs no such
/// answer, because no code can reach it at all.
///
/// Runs from `PostLaunchWork`, which `LaunchEnvironment.finishLaunch()` reaches after marking the
/// first frame presented: removing thousands of keys costs 165ms to 230ms, and
/// `applicationDidBecomeActive` fires before that frame. Safe there because AppKit reads a record
/// once, when `autosaveName` is assigned, and measured, removing a record a live split view still
/// owns changes no geometry on screen and is rewritten by that view's next save.
@MainActor
internal enum SplitViewAutosaveSweep {
    private static let logger = Logger(subsystem: "com.TablePro", category: "Launch")

    private static var hasSwept = false

    /// The records to drop, given every defaults key present.
    internal static func deadKeys(among keys: some Sequence<String>) -> [String] {
        keys.filter { SplitViewAutosaveRecord.parse(key: $0) == .retiredPerTabQuerySplit }
    }

    /// Idempotent, matching `PostLaunchWork.start()`, which more than one path reaches.
    internal static func sweepIfNeeded() async {
        guard !hasSwept else { return }
        hasSwept = true

        /// AppKit files these in the process's own standard domain, which a UI test's redirected
        /// suite never receives; `SplitViewAutosaveName` exists to stop cases inheriting each
        /// other's geometry through it. A sandboxed run therefore shares the developer's real
        /// records and has no business deleting them.
        guard !AppStorageEnvironment.shared.isIsolated else { return }

        let defaults = UserDefaults.standard
        let doomed = deadKeys(among: defaults.dictionaryRepresentation().keys)

        guard !doomed.isEmpty else { return }
        for key in doomed {
            defaults.removeObject(forKey: key)
        }
        logger.info("swept \(doomed.count) retired per-tab split-view autosave records")
    }
}

private extension String {
    /// Nil when the prefix is absent, so a caller can tell "not this family" from "this family with
    /// an empty remainder".
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
