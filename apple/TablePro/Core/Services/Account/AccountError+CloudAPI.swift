//
//  AccountError+CloudAPI.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

extension AccountError {
    static func problem(_ problem: Components.Schemas.Problem) -> AccountError {
        .server(status: Int(problem.status), code: problem.code)
    }

    // The generated client wraps what a middleware or the transport throws.
    static func from(_ error: any Error) -> AccountError {
        switch error {
        case let error as AccountError:
            return error
        case let error as ClientError:
            return from(error.underlyingError)
        case is CancellationError:
            return .canceled
        case let error as URLError where error.code == .cancelled:
            return .canceled
        default:
            return .network(error.localizedDescription)
        }
    }
}
