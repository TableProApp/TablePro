//
//  SSLModeResolution.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum SSLModeOrigin: Equatable {
    case typeDefault
    case impliedByPort
    case chosen
}

struct SSLModeResolution: Equatable {
    let mode: SSLMode
    let origin: SSLModeOrigin
}
