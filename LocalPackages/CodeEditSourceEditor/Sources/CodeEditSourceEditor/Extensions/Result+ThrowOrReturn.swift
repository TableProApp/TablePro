//
//  Result+ThrowOrReturn.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 9/2/24.
//

import Foundation

extension Result {
    func throwOrReturn() throws -> Success {
        switch self {
        case let .success(success):
            return success
        case let .failure(failure):
            throw failure
        }
    }

    var isSuccess: Bool {
        if case .success = self {
            return true
        } else {
            return false
        }
    }
}
