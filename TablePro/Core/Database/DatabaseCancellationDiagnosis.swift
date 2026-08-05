//
//  DatabaseCancellationDiagnosis.swift
//  TablePro
//

import Foundation

internal enum DatabaseCancellationDiagnosis {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}
