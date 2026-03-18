//
//  CaptureModifierSet.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 12/16/24.
//

/// A set of capture modifiers, efficiently represented by a single integer.
public struct CaptureModifierSet: OptionSet, Equatable, Hashable, Sendable {
    public var rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let declaration = CaptureModifierSet(rawValue: 1 << CaptureModifier.declaration.rawValue)
    public static let definition = CaptureModifierSet(rawValue: 1 << CaptureModifier.definition.rawValue)
    public static let readonly = CaptureModifierSet(rawValue: 1 << CaptureModifier.readonly.rawValue)
    public static let `static` = CaptureModifierSet(rawValue: 1 << CaptureModifier.static.rawValue)
    public static let deprecated = CaptureModifierSet(rawValue: 1 << CaptureModifier.deprecated.rawValue)
    public static let abstract = CaptureModifierSet(rawValue: 1 << CaptureModifier.abstract.rawValue)
    public static let async = CaptureModifierSet(rawValue: 1 << CaptureModifier.async.rawValue)
    public static let modification = CaptureModifierSet(rawValue: 1 << CaptureModifier.modification.rawValue)
    public static let documentation = CaptureModifierSet(rawValue: 1 << CaptureModifier.documentation.rawValue)
    public static let defaultLibrary = CaptureModifierSet(rawValue: 1 << CaptureModifier.defaultLibrary.rawValue)

    /// All values in the set.
    ///
    /// Results will be returned in order of ``CaptureModifier``'s raw value.
    /// This variable ignores garbage values in the ``rawValue`` property.
    public var values: [CaptureModifier] {
        var rawValue = self.rawValue

        // This set is represented by an integer, where each `1` in the binary number represents a value.
        // We can interpret the index of the `1` as the raw value of a ``CaptureModifier`` (the index in 0b0100 would
        // be 2). This loops through each `1` in the `rawValue`, finds the represented modifier, and 0's out the `1` so
        // we can get the next one using the binary & operator (0b0110 -> 0b0100 -> 0b0000 -> finish).
        var values: [Int8] = []
        while rawValue > 0 {
            values.append(Int8(rawValue.trailingZeroBitCount))
            // Clears the bit at the desired index (eg: 0b110 if clearing index 0)
            rawValue &= ~UInt(1 << rawValue.trailingZeroBitCount)
        }
        return values.compactMap({ CaptureModifier(rawValue: $0) })
    }

    /// Inserts the modifier into the set.
    public mutating func insert(_ value: CaptureModifier) {
        rawValue |= 1 << value.rawValue
    }
}
