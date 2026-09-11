//
//  WelcomeContextMenuKind.swift
//  TablePro
//

import Foundation

internal enum WelcomeContextMenuKind: Equatable {
    case newConnection
    case singleConnection
    case multipleConnections
    case externalOnly

    internal static func resolve(savedCount: Int, externalCount: Int) -> WelcomeContextMenuKind {
        guard savedCount > 0 else {
            return externalCount > 0 ? .externalOnly : .newConnection
        }
        return savedCount + externalCount == 1 ? .singleConnection : .multipleConnections
    }
}
