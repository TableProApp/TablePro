//
//  RowDisplayBox.swift
//  TablePro
//

import Foundation

final class RowIDKey: NSObject {
    let id: RowID

    init(_ id: RowID) {
        self.id = id
        super.init()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? RowIDKey else { return false }
        return other.id == id
    }

    override var hash: Int { id.hashValue }
}

final class RowDisplayBox: NSObject {
    var values: ContiguousArray<String?>

    init(_ values: ContiguousArray<String?>) {
        self.values = values
        super.init()
    }
}
