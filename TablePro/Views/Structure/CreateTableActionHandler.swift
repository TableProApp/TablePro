//
//  CreateTableActionHandler.swift
//  TablePro
//

import Foundation

@MainActor
final class CreateTableActionHandler {
    var createTable: (() -> Void)?
    var undo: (() -> Void)?
    var redo: (() -> Void)?
}
