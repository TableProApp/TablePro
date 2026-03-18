//
//  TextView+createReadBlock.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/20/23.
//

import Foundation
import CodeEditTextView
import SwiftTreeSitter

extension TextView {
    /// Creates a block for safely reading data into a parser's read block.
    ///
    /// If the thread is the main queue, executes synchronously.
    /// Otherwise it will block the calling thread and execute the block on the main queue, returning control to the
    /// calling queue when the block is finished running.
    ///
    /// - Returns: A new block for reading contents for tree-sitter.
    func createReadBlock() -> Parser.ReadBlock {
        return { [weak self] byteOffset, _ in
            let workItem: () -> Data? = {
                let limit = self?.documentRange.length ?? 0
                let location = byteOffset / 2
                let end = min(location + (TreeSitterClient.Constants.charsToReadInBlock), limit)
                if location > end || self == nil {
                    // Ignore and return nothing, tree-sitter's internal tree can be incorrect in some situations.
                    return nil
                }
                let range = NSRange(location..<end)
                return self?.textStorage.substring(from: range)?.data(using: String.nativeUTF16Encoding)
            }
            return DispatchQueue.waitMainIfNot(workItem)
        }
    }
    /// Creates a block for safely reading data for a text provider.
    ///
    /// If the thread is the main queue, executes synchronously.
    /// Otherwise it will block the calling thread and execute the block on the main queue, returning control to the
    /// calling queue when the block is finished running.
    ///
    /// - Returns: A new block for reading contents for tree-sitter.
    func createReadCallback() -> SwiftTreeSitter.Predicate.TextProvider {
        return { [weak self] range, _ in
            let workItem: () -> String? = {
                self?.textStorage.substring(from: range)
            }
            return DispatchQueue.waitMainIfNot(workItem)
        }
    }
}
