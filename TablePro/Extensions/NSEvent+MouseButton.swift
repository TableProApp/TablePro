//
//  NSEvent+MouseButton.swift
//  TablePro
//

import AppKit

internal extension NSEvent {
    /// The wheel button, which AppKit numbers 2 and reports through the `otherMouse` family rather
    /// than routing an action for. Everything above it is a side button on a five-button mouse and
    /// belongs to whatever else claims it.
    var isMiddleButton: Bool {
        buttonNumber == 2
    }
}
