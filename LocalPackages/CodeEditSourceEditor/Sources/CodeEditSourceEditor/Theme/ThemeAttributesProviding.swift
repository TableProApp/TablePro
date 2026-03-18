//
//  ThemeAttributesProviding.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 1/18/23.
//

import Foundation

/// Classes conforming to this protocol can provide attributes for text given a capture type.
public protocol ThemeAttributesProviding: AnyObject {
    func attributesFor(_ capture: CaptureName?) -> [NSAttributedString.Key: Any]
}
