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
        record(loaded.content, stamp: loaded.stamp, in: &tab.content)
    }

    internal static func hydrate(_ tabs: inout [QueryTab]) {
        for index in tabs.indices {
            hydrate(&tabs[index])
        }
    }

    internal static func adopt(_ loaded: FileTextLoader.LoadedText, into content: inout TabQueryContent) {
        adopt(text: loaded.content, stamp: loaded.stamp, into: &content)
    }

    internal static func adopt(text: String, stamp: FileStamp?, into content: inout TabQueryContent) {
        content.query = text
        record(text, stamp: stamp, in: &content)
    }

    internal static func recordWrite(of text: String, to url: URL, in content: inout TabQueryContent) {
        record(text, stamp: FileStamp.read(url), in: &content)
    }

    internal static func diskChange(in content: TabQueryContent) -> SourceFileDiskChange? {
        guard let url = content.sourceFileURL else { return nil }
        return diskChange(in: content, current: FileStamp.read(url))
    }

    internal static func diskChange(in content: TabQueryContent, current: FileStamp?) -> SourceFileDiskChange? {
        guard content.sourceFileURL != nil else { return nil }
        return SourceFileDiskChange.detect(recorded: content.savedFileStamp, current: current)
    }

    internal static func settle(_ detected: SourceFileDiskChange?, in content: inout TabQueryContent) {
        guard detected != content.dismissedDiskChange else {
            content.diskChange = nil
            return
        }
        content.dismissedDiskChange = nil
        content.diskChange = detected
    }

    internal static func showDiskChange(_ change: SourceFileDiskChange, in content: inout TabQueryContent) {
        content.diskChange = change
        content.dismissedDiskChange = nil
    }

    internal static func dismissDiskChange(in content: inout TabQueryContent) {
        content.dismissedDiskChange = content.diskChange
        content.diskChange = nil
    }

    private static func record(_ text: String, stamp: FileStamp?, in content: inout TabQueryContent) {
        content.savedFileContent = text
        content.savedFileStamp = stamp
        content.diskChange = nil
        content.dismissedDiskChange = nil
    }
}
