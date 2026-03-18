//
//  WeakCoordinator.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 9/13/24.
//

struct WeakCoordinator {
    weak var val: TextViewCoordinator?

    init(_ val: TextViewCoordinator) {
        self.val = val
    }
}

extension Array where Element == WeakCoordinator {
    mutating func clean() {
        self.removeAll(where: { $0.val == nil })
    }

    mutating func values() -> [TextViewCoordinator] {
        self.clean()
        return self.compactMap({ $0.val })
    }
}
