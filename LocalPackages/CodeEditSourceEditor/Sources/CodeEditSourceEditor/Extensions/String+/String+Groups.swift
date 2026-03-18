//
//  NewlineProcessingFilter+TagHandling.swift
//  CodeEditSourceEditor
//
//  Created by Roscoe Rubin-Rottenberg on 5/19/24.
//

import Foundation
import TextStory
import TextFormation

// Helper extension to extract capture groups
extension String {
    func groups(for regexPattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: regexPattern) else { return nil }
        let nsString = self as NSString
        let results = regex.matches(in: self, range: NSRange(location: 0, length: nsString.length))
        return results.first.map { result in
            (1..<result.numberOfRanges).compactMap {
                result.range(at: $0).location != NSNotFound ? nsString.substring(with: result.range(at: $0)) : nil
            }
        }
    }
}
