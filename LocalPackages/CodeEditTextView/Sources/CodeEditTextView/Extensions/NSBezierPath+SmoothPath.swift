//
//  NSBezierPath+SmoothPath.swift
//  CodeEditSourceEditor
//
//  Created by Tom Ludwig on 12.11.24.
//

import AppKit
import SwiftUI

extension NSBezierPath {
    private func quadCurve(to endPoint: CGPoint, controlPoint: CGPoint) {
        guard pointIsValid(endPoint) && pointIsValid(controlPoint) else { return }

        let startPoint = self.currentPoint
        let controlPoint1 = CGPoint(x: (startPoint.x + (controlPoint.x - startPoint.x) * 2.0 / 3.0),
                                    y: (startPoint.y + (controlPoint.y - startPoint.y) * 2.0 / 3.0))
        let controlPoint2 = CGPoint(x: (endPoint.x + (controlPoint.x - endPoint.x) * 2.0 / 3.0),
                                    y: (endPoint.y + (controlPoint.y - endPoint.y) * 2.0 / 3.0))

        curve(to: endPoint, controlPoint1: controlPoint1, controlPoint2: controlPoint2)
    }

    private func pointIsValid(_ point: CGPoint) -> Bool {
        return !point.x.isNaN && !point.y.isNaN
    }

    // swiftlint:disable:next function_body_length
    static func smoothPath(_ points: [NSPoint], radius cornerRadius: CGFloat) -> NSBezierPath {
        // Normalizing radius to compensate for the quadraticCurve
        let radius = cornerRadius * 1.15

        let path = NSBezierPath()

        guard points.count > 1 else { return path }

        // Calculate the initial corner start based on the first two points
        let initialVector = NSPoint(x: points[1].x - points[0].x, y: points[1].y - points[0].y)
        let initialDistance = sqrt(initialVector.x * initialVector.x + initialVector.y * initialVector.y)

        let initialUnitVector = NSPoint(x: initialVector.x / initialDistance, y: initialVector.y / initialDistance)
        let initialCornerStart = NSPoint(
            x: points[0].x + initialUnitVector.x * radius,
            y: points[0].y + initialUnitVector.y * radius
        )

        // Start path at the initial corner start
        path.move(to: points.first == points.last ? initialCornerStart : points[0])

        for index in 1..<points.count - 1 {
            let p0 = points[index - 1]
            let p1 = points[index]
            let p2 = points[index + 1]

            // Calculate vectors
            let vector1 = NSPoint(x: p1.x - p0.x, y: p1.y - p0.y)
            let vector2 = NSPoint(x: p2.x - p1.x, y: p2.y - p1.y)

            // Calculate unit vectors and distances
            let distance1 = sqrt(vector1.x * vector1.x + vector1.y * vector1.y)
            let distance2 = sqrt(vector2.x * vector2.x + vector2.y * vector2.y)

            if distance1.isZero || distance2.isZero {
                // Dividing by 0 will result in `NaN` points.
                continue
            }
            let unitVector1 = distance1 > 0 ? NSPoint(x: vector1.x / distance1, y: vector1.y / distance1) : NSPoint.zero
            let unitVector2 = distance2 > 0 ? NSPoint(x: vector2.x / distance2, y: vector2.y / distance2) : NSPoint.zero

            // Calculate the corner start and end
            let cornerStart = NSPoint(x: p1.x - unitVector1.x * radius, y: p1.y - unitVector1.y * radius)
            let cornerEnd = NSPoint(x: p1.x + unitVector2.x * radius, y: p1.y + unitVector2.y * radius)

            // Check if this segment is a straight line or a curve
            if unitVector1 != unitVector2 {  // There's a change in direction, add a curve
                path.line(to: cornerStart)
                path.quadCurve(to: cornerEnd, controlPoint: p1)
            } else {  // Straight line, just add a line
                path.line(to: p1)
            }
        }

        // Handle the final segment if the path is closed
        if points.first == points.last, points.count > 2 {
            // Closing path by rounding back to the initial point
            let lastPoint = points[points.count - 2]
            let firstPoint = points[0]

            // Calculate the vectors and unit vectors
            let finalVector = NSPoint(x: firstPoint.x - lastPoint.x, y: firstPoint.y - lastPoint.y)
            let distance = sqrt(finalVector.x * finalVector.x + finalVector.y * finalVector.y)

            // Dividing by 0 after this will cause an assertion failure. Something went wrong with the given points
            // this could mean we're rounding a 0-width and 0-height rect.
            guard distance != 0 else {
                path.line(to: lastPoint)
                return path
            }

            let unitVector = NSPoint(x: finalVector.x / distance, y: finalVector.y / distance)

            // Calculate the final corner start and initial corner end
            let finalCornerStart = NSPoint(
                x: firstPoint.x - unitVector.x * radius,
                y: firstPoint.y - unitVector.y * radius
            )

            let initialCornerEnd = NSPoint(
                x: points[0].x + initialUnitVector.x * radius,
                y: points[0].y + initialUnitVector.y * radius
            )

            path.line(to: finalCornerStart)
            path.quadCurve(to: initialCornerEnd, controlPoint: firstPoint)
            path.close()

        } else if let lastPoint = points.last {  // For open paths, just connect to the last point
            path.line(to: lastPoint)
        }

        return path
    }
}
