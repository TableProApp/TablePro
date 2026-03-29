//
//  HorizontalEdgeInsets.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/11/23.
//

import Foundation

public struct HorizontalEdgeInsets: Codable, Sendable, Equatable, AdditiveArithmetic {
    public var left: CGFloat
    public var right: CGFloat

    public var horizontal: CGFloat {
        left + right
    }

    public init(left: CGFloat, right: CGFloat) {
        self.left = left
        self.right = right
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.left = try container.decode(CGFloat.self, forKey: .left)
        self.right = try container.decode(CGFloat.self, forKey: .right)
    }

    public static let zero: HorizontalEdgeInsets = {
        HorizontalEdgeInsets(left: 0, right: 0)
    }()

    public static func + (lhs: HorizontalEdgeInsets, rhs: HorizontalEdgeInsets) -> HorizontalEdgeInsets {
        HorizontalEdgeInsets(left: lhs.left + rhs.left, right: lhs.right + rhs.right)
    }

    public static func - (lhs: HorizontalEdgeInsets, rhs: HorizontalEdgeInsets) -> HorizontalEdgeInsets {
        HorizontalEdgeInsets(left: lhs.left - rhs.left, right: lhs.right - rhs.right)
    }
}
