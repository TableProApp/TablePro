//
//  KillRing.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/13/24.
//

import Foundation

// swiftlint:disable line_length

/// A global kill ring similar to emacs. With support for killing and yanking multiple cursors.
///
/// Documentation sources:
/// - [Emacs kill ring](https://www.gnu.org/software/emacs/manual/html_node/emacs/Yanking.html)
/// - [Cocoa Docs](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TextDefaultsBindings/TextDefaultsBindings.html)
class KillRing {
    static let shared: KillRing = KillRing()

    // swiftlint:enable line_length

    private static let bufferSizeKey = "NSTextKillRingSize"

    private var buffer: [[String]]
    private var index = 0

    init(_ size: Int? = nil) {
        buffer = Array(
            repeating: [""],
            count: size ?? max(1, UserDefaults.standard.integer(forKey: Self.bufferSizeKey))
        )
    }

    /// Performs the kill action in response to a delete action. Saving the deleted text to the kill ring.
    func kill(strings: [String]) {
        incrementIndex()
        buffer[index] = strings
    }

    /// Yanks the current item in the ring.
    func yank() -> [String] {
        return buffer[index]
    }

    /// Yanks an item from the ring, and selects the next one in the ring.
    func yankAndSelect() -> [String] {
        let retVal = buffer[index]
        incrementIndex()
        return retVal
    }

    private func incrementIndex() {
        index = (index + 1) % buffer.count
    }
}
