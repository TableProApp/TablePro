//
//  CopyDataPieces.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

enum CopyDataPieces {
    static let pieceSize = 64 * 1_024

    // A piece may end inside a row, even inside a character: the server reads a copy's data as one byte stream.
    static func reading(_ text: String) -> PluginCopyData {
        let data = Data(text.utf8)
        let offset = OSAllocatedUnfairLock(initialState: data.startIndex)
        return PluginCopyData {
            offset.withLock { start in
                guard start < data.endIndex else { return nil }
                let end = min(start + Self.pieceSize, data.endIndex)
                defer { start = end }
                return data.subdata(in: start..<end)
            }
        }
    }
}
