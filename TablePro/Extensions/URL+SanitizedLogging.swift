//
//  URL+SanitizedLogging.swift
//  TablePro
//

import Foundation

internal extension URL {
    var sanitizedForLogging: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              components.password != nil else {
            return absoluteString
        }
        components.password = "***"
        return components.string ?? absoluteString
    }
}
