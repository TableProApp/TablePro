//
//  KeyCode.swift
//  TablePro
//
//  Semantic enum for keyboard key codes used throughout the app.
//  Eliminates magic numbers and improves code readability.
//
//  Reference: https://eastmanreference.com/complete-list-of-applescript-key-codes
//

import AppKit

/// Semantic enum for NSEvent key codes
///
/// Usage:
/// ```swift
/// override func keyDown(with event: NSEvent) {
///     guard let key = KeyCode(rawValue: event.keyCode) else {
///         super.keyDown(with: event)
///         return
///     }
///
///     switch key {
///     case .escape:
///         // Handle ESC
///     case .delete:
///         // Handle Delete
///     default:
///         super.keyDown(with: event)
///     }
/// }
/// ```
public enum KeyCode: UInt16 {
    // MARK: - Special Keys

    /// Escape key (ESC)
    case escape = 53

    /// Return/Enter key (main keyboard)
    case `return` = 36

    /// Enter key (numeric keypad)
    case enter = 76

    /// Tab key
    case tab = 48

    /// Space bar
    case space = 49

    /// Delete/Backspace key
    case delete = 51

    /// Forward Delete key (Fn+Delete on most Macs)
    case forwardDelete = 117

    // MARK: - Arrow Keys

    /// Up arrow
    case upArrow = 126

    /// Down arrow
    case downArrow = 125

    /// Left arrow
    case leftArrow = 123

    /// Right arrow
    case rightArrow = 124

    // MARK: - Navigation Keys

    /// Home key
    case home = 115

    /// End key
    case end = 119

    /// Page Up key
    case pageUp = 116

    /// Page Down key
    case pageDown = 121

    // MARK: - Letter Keys (for Cmd+ shortcuts)

    case a = 0
    case b = 11
    case c = 8
    case d = 2
    case e = 14
    case f = 3
    case g = 5
    case h = 4
    case i = 34
    case j = 38
    case k = 40
    case l = 37
    case m = 46
    case n = 45
    case o = 31
    case p = 35
    case q = 12
    case r = 15
    case s = 1
    case t = 17
    case u = 32
    case v = 9
    case w = 13
    case x = 7
    case y = 16
    case z = 6

    // MARK: - Number Keys

    case zero = 29
    case one = 18
    case two = 19
    case three = 20
    case four = 21
    case five = 23
    case six = 22
    case seven = 26
    case eight = 28
    case nine = 25

    // MARK: - Function Keys

    case f1 = 122
    case f2 = 120
    case f3 = 99
    case f4 = 118
    case f5 = 96
    case f6 = 97
    case f7 = 98
    case f8 = 100
    case f9 = 101
    case f10 = 109
    case f11 = 103
    case f12 = 111

    // MARK: - Convenience Methods

    /// Check if the key code represents an arrow key
    public var isArrowKey: Bool {
        switch self {
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            return true
        default:
            return false
        }
    }

    /// Check if the key code represents a letter
    public var isLetter: Bool {
        switch self {
        case .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
             .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z:
            return true
        default:
            return false
        }
    }

    /// Check if the key code represents a number
    public var isNumber: Bool {
        switch self {
        case .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine:
            return true
        default:
            return false
        }
    }

    /// Create a KeyCode from an NSEvent
    public init?(event: NSEvent) {
        self.init(rawValue: event.keyCode)
    }
}

// MARK: - NSEvent Extension

public extension NSEvent {
    /// The semantic key code for this event, if recognized
    var semanticKeyCode: KeyCode? {
        KeyCode(rawValue: keyCode)
    }
}
