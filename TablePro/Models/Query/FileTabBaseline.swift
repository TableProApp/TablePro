//
//  FileTabBaseline.swift
//  TablePro
//

import Foundation

/// What a tab backed by a `.sql` file on disk compares itself against.
///
/// A tab rebuilt from a persisted record carries the text it was saved with and nothing to compare
/// it to, and `TabQueryContent.isFileDirty` reads a missing baseline as clean. A tab in that state
/// lies about itself three ways: it shows no unsaved marker, Save skips it because it believes
/// there is nothing to write, and reopening the file replaces what it holds. Restoring at launch
/// already read the baseline back; reopening a closed tab did not, so the same tab was honest
/// through one door and not the other.
///
/// Every path that rebuilds a file-backed tab reads it back here, so there is one door.
internal enum FileTabBaseline {
    internal static func hydrate(_ tab: inout QueryTab) {
        guard let url = tab.content.sourceFileURL, let loaded = FileTextLoader.load(url) else { return }
        tab.content.savedFileContent = loaded.content
        tab.content.loadMtime = loaded.modifiedAt
    }

    internal static func hydrate(_ tabs: inout [QueryTab]) {
        for index in tabs.indices {
            hydrate(&tabs[index])
        }
    }
}
