//
//  SetValueCommandResponding.swift
//  TablePro
//

import AppKit

/// Edit > Set Value, named once so the menu builder needs no class. The focused data grid answers,
/// for the cells it has selected; anywhere else the items stay in the menu, dimmed.
@MainActor
@objc protocol SetValueCommandResponding {
    func setValueEmpty(_ sender: Any?)
    func setValueNull(_ sender: Any?)
    func setValueDefault(_ sender: Any?)
    func generateUUIDv4(_ sender: Any?)
    func generateUUIDv7(_ sender: Any?)
    func setCellsToValue(_ sender: Any?)
}
