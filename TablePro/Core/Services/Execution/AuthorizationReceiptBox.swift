//
//  AuthorizationReceiptBox.swift
//  TablePro
//

import Foundation

internal enum AuthorizationReceiptBox {
    @TaskLocal static var current: OperationReceipt?
}
