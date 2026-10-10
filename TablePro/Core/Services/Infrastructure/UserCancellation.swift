//
//  UserCancellation.swift
//  TablePro
//

import Foundation

internal extension Error {
    /// A cancel the user asked for, which no alert should report back to them.
    var isUserCancellation: Bool {
        if (self as? DatabaseAccessError)?.isUserCancelled == true { return true }
        return ConnectionFailureClassifier.isUserCancelled(self)
    }
}
