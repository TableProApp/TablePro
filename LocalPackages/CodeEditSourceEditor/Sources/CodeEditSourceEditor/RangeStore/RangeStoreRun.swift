//
//  RangeStoreRun.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 11/4/24.
//

/// Consumer-facing value type for the stored values in this container.
struct RangeStoreRun<Element: RangeStoreElement>: Equatable, Hashable {
    var length: Int
    var value: Element?

    static func empty(length: Int) -> Self {
        RangeStoreRun(length: length, value: nil)
    }

    var isEmpty: Bool {
        value?.isEmpty ?? true
    }

    mutating func subtractLength(_ other: borrowing RangeStoreRun) {
        self.length -= other.length
    }
}

extension RangeStoreRun: CustomDebugStringConvertible {
    var debugDescription: String {
        if let value = value as? CustomDebugStringConvertible {
            "\(length) (\(value.debugDescription))"
        } else {
            "\(length) (empty)"
        }
    }
}
