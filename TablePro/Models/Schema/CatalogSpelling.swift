//
//  CatalogSpelling.swift
//  TablePro
//

import Foundation

/// A spelling read from the catalog, with the value of the field it spells.
///
/// It applies only while the field still holds that value, so an edit retires it and undoing the
/// edit brings it back.
struct CatalogSpelling<Value: Hashable>: Hashable {
    let value: Value
    let spelling: String

    func spelling(for current: Value?) -> String? {
        current == value ? spelling : nil
    }
}

extension CatalogSpelling: Sendable where Value: Sendable {}
