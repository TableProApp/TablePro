//
//  CreateTableActionHandler.swift
//  TablePro
//

import Foundation

@MainActor
final class CreateTableActionHandler {
    var createTable: (() -> Void)?
}
