//
//  LogRedaction.swift
//  TablePro
//

import Foundation
import TableProLogRedaction

internal extension Error {
    var publicLogShape: String { LogRedaction.publicDescription(of: self) }
}
