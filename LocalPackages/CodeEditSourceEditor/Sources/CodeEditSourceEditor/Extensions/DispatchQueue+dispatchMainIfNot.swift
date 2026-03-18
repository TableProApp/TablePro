//
//  DispatchQueue+dispatchMainIfNot.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 9/2/24.
//

import Foundation

/// Helper methods for dispatching (sync or async) on the main queue only if the calling thread is not already the
/// main queue.

extension DispatchQueue {
    /// Executes the work item on the main thread, dispatching asynchronously if the thread is not the main thread.
    /// - Parameter item: The work item to execute on the main thread.
    static func dispatchMainIfNot(_ item: @escaping () -> Void) {
        if Thread.isMainThread {
            item()
        } else {
            DispatchQueue.main.async {
                item()
            }
        }
    }

    /// Executes the work item on the main thread, keeping control on the calling thread until the work item is
    /// executed if not already on the main thread.
    /// - Parameter item: The work item to execute.
    /// - Returns: The value of the work item.
    static func waitMainIfNot<T>(_ item: () -> T) -> T {
        if Thread.isMainThread {
            return item()
        } else {
            return DispatchQueue.main.sync(execute: item)
        }
    }
}
