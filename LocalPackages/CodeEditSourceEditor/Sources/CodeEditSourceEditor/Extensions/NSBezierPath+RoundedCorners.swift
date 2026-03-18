//
//  NSBezierPath+RoundedCorners.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/3/25.
//

import AppKit

// Wonderful NSBezierPath extension taken with modification from the playground code at:
// https://github.com/janheiermann/BezierPath-Corners

extension NSBezierPath {
    struct Corners: OptionSet {
        public let rawValue: Int

        public init(rawValue: Corners.RawValue) {
            self.rawValue = rawValue
        }

        public static let topLeft = Corners(rawValue: 1 << 0)
        public static let bottomLeft = Corners(rawValue: 1 << 1)
        public static let topRight = Corners(rawValue: 1 << 2)
        public static let bottomRight = Corners(rawValue: 1 << 3)
        public static let all: Corners = Corners(rawValue: 0b1111)
    }

    // swiftlint:disable:next function_body_length
    convenience init(rect: CGRect, roundedCorners corners: Corners, cornerRadius: CGFloat) {
        self.init()

        let maxX = rect.maxX
        let minX = rect.minX
        let maxY = rect.maxY
        let minY = rect.minY
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)

        // Start at bottom-left corner
        move(to: CGPoint(x: minX + (corners.contains(.bottomLeft) ? radius : 0), y: minY))

        // Bottom edge
        if corners.contains(.bottomRight) {
            line(to: CGPoint(x: maxX - radius, y: minY))
            appendArc(
                withCenter: CGPoint(x: maxX - radius, y: minY + radius),
                radius: radius,
                startAngle: 270,
                endAngle: 0,
                clockwise: false
            )
        } else {
            line(to: CGPoint(x: maxX, y: minY))
        }

        // Right edge
        if corners.contains(.topRight) {
            line(to: CGPoint(x: maxX, y: maxY - radius))
            appendArc(
                withCenter: CGPoint(x: maxX - radius, y: maxY - radius),
                radius: radius,
                startAngle: 0,
                endAngle: 90,
                clockwise: false
            )
        } else {
            line(to: CGPoint(x: maxX, y: maxY))
        }

        // Top edge
        if corners.contains(.topLeft) {
            line(to: CGPoint(x: minX + radius, y: maxY))
            appendArc(
                withCenter: CGPoint(x: minX + radius, y: maxY - radius),
                radius: radius,
                startAngle: 90,
                endAngle: 180,
                clockwise: false
            )
        } else {
            line(to: CGPoint(x: minX, y: maxY))
        }

        // Left edge
        if corners.contains(.bottomLeft) {
            line(to: CGPoint(x: minX, y: minY + radius))
            appendArc(
                withCenter: CGPoint(x: minX + radius, y: minY + radius),
                radius: radius,
                startAngle: 180,
                endAngle: 270,
                clockwise: false
            )
        } else {
            line(to: CGPoint(x: minX, y: minY))
        }

        close()
    }

    convenience init(roundingRect: CGRect, capTop: Bool, capBottom: Bool, cornerRadius radius: CGFloat) {
        switch (capTop, capBottom) {
        case (true, true):
            self.init(rect: roundingRect)
        case (false, true):
            self.init(rect: roundingRect, roundedCorners: [.bottomLeft, .bottomRight], cornerRadius: radius)
        case (true, false):
            self.init(rect: roundingRect, roundedCorners: [.topLeft, .topRight], cornerRadius: radius)
        case (false, false):
            self.init(roundedRect: roundingRect, xRadius: radius, yRadius: radius)
        }
    }
}
