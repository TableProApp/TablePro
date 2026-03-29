//
//  NSBezierPath+CGPathFallback.swift
//  CodeEditTextView
//
//  Created by Tom Ludwig on 27.11.24.
//

import AppKit

extension NSBezierPath {
    /// Converts the `NSBezierPath` instance into a `CGPath`, providing a fallback method for compatibility(macOS < 14).
    public var cgPathFallback: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)

        for index in 0 ..< elementCount {
            let type = element(at: index, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            default:
                continue
            }
        }

        return path
    }
}
