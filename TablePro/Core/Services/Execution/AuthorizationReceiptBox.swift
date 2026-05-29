//
//  AuthorizationReceiptBox.swift
//  TablePro
//

import Foundation
import os

internal enum AuthorizationReceiptBox {
    @TaskLocal static var current: OperationReceipt?

    private static let logger = Logger(subsystem: "com.TablePro", category: "ExecutionBackstop")

    static func auditWrite(operation: String, connectionId: UUID, kind: OperationKind) {
        guard current == nil else { return }
        logger.fault(
            "Write reached driver without authorization: op=\(operation, privacy: .public) kind=\(String(describing: kind), privacy: .public) connection=\(connectionId, privacy: .public)"
        )
    }
}
