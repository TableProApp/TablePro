//
//  ForwardingScrollView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/15/25.
//

import Cocoa

/// A custom ``NSScrollView`` subclass that forwards scroll wheel events to another scroll view.
/// This class does not process any other scrolling events. However, it still lays out it's contents like a
/// regular scroll view.
///
/// Set ``receiver`` to target events.
open class ForwardingScrollView: NSScrollView {
    /// The target scroll view to send scroll events to.
    open weak var receiver: NSScrollView?

    open override func scrollWheel(with event: NSEvent) {
        receiver?.scrollWheel(with: event)
    }
}
