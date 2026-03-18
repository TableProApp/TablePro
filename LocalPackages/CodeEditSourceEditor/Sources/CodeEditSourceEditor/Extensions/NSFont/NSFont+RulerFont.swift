//
//  NSFont+RulerFont.swift
//  CodeEditSourceEditor
//
//  Created by Elias Wahl on 17.03.23.
//

import Foundation
import AppKit

extension NSFont {
    var rulerFont: NSFont {
        let fontSize: Double = (self.pointSize - 1) + 0.25
        let fontAdvance: Double = self.pointSize * 0.49 + 0.1
        let fontWeight = NSFont.Weight(rawValue: self.pointSize * 0.00001 + 0.0001)
        let fontWidth = NSFont.Width(rawValue: -0.13)

        let font = NSFont.systemFont(ofSize: fontSize, weight: fontWeight, width: fontWidth)

        /// Set the open four
        let alt4: [NSFontDescriptor.FeatureKey: Int] = [
            .selectorIdentifier: kStylisticAltOneOnSelector,
            .typeIdentifier: kStylisticAlternativesType
        ]

        /// Set alternate styling for 6 and 9
        let alt6and9: [NSFontDescriptor.FeatureKey: Int] = [
            .selectorIdentifier: kStylisticAltTwoOnSelector,
            .typeIdentifier: kStylisticAlternativesType
        ]

        /// Make all digits monospaced
        let monoSpaceDigits: [NSFontDescriptor.FeatureKey: Int] = [
            .selectorIdentifier: 0,
            .typeIdentifier: kNumberSpacingType
        ]

        let features = [alt4, alt6and9, monoSpaceDigits]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features, .fixedAdvance: fontAdvance])
        return NSFont(descriptor: descriptor, size: 0) ?? font
    }
}
