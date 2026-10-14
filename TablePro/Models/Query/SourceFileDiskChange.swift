//
//  SourceFileDiskChange.swift
//  TablePro
//

import Foundation
import TableProUtilities

internal enum SourceFileDiskChange: Equatable, Sendable {
    case modified(FileStamp)
    case missing

    static func detect(recorded: FileStamp?, current: FileStamp?) -> SourceFileDiskChange? {
        guard let current else { return .missing }
        guard let recorded, current != recorded else { return nil }
        return .modified(current)
    }
}
