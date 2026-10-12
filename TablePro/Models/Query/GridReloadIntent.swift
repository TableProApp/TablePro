//
//  GridReloadIntent.swift
//  TablePro
//

import Foundation

internal enum GridReloadIntent: Equatable, Sendable {
    case firstRow
    case keepPlace
    case restoreRow([String: String])
}
