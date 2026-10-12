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

    /// A deep link's query holds SQL, pairing state and redirect addresses; the names are enough
    /// to tell which parameter a parse failure was about.
    var queryValuesRedactedForLogging: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return scheme.map { "\($0):" } ?? ""
        }
        if components.password != nil {
            components.password = "***"
        }
        components.percentEncodedQueryItems = components.percentEncodedQueryItems?.map { item in
            URLQueryItem(name: item.name, value: item.value == nil ? nil : "***")
        }
        components.fragment = nil
        return components.string ?? scheme.map { "\($0):" } ?? ""
    }
}
