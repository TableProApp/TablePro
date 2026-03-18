//
//  NSRange+NSTextRange.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 9/13/22.
//

import AppKit

public extension NSTextRange {
    convenience init?(_ range: NSRange, provider: NSTextElementProvider) {
        let docLocation = provider.documentRange.location

        guard let start = provider.location?(docLocation, offsetBy: range.location) else {
            return nil
        }

        guard let end = provider.location?(start, offsetBy: range.length) else {
            return nil
        }

        self.init(location: start, end: end)
    }

    /// Creates an `NSRange` using document information from the given provider.
    /// - Parameter provider: The `NSTextElementProvider` to use to convert this range into an `NSRange`
    /// - Returns: An `NSRange` if possible
    func nsRange(using provider: NSTextElementProvider) -> NSRange? {
        guard let location = provider.offset?(from: provider.documentRange.location, to: location) else {
            return nil
        }
        guard let length = provider.offset?(from: self.location, to: endLocation) else {
            return nil
        }
        return NSRange(location: location, length: length)
    }
}
