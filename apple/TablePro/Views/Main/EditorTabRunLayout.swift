//
//  EditorTabRunLayout.swift
//  TablePro
//

import CoreGraphics
import Foundation

internal struct EditorTabRunLayout: Equatable {
    internal let viewportWidth: CGFloat
    internal let count: Int
    internal let tabWidth: CGFloat

    internal init(viewportWidth: CGFloat, count: Int) {
        self.viewportWidth = max(viewportWidth, 0)
        self.count = max(count, 0)
        tabWidth = EditorTabStripLayout.tabWidth(forViewport: self.viewportWidth, count: self.count)
    }

    internal var contentWidth: CGFloat {
        tabWidth * CGFloat(count)
    }

    internal var maximumOffset: CGFloat {
        max(contentWidth - viewportWidth, 0)
    }

    // The system bar narrows the tabs past either edge, which is what says more tabs are there.
    private var collapseZone: CGFloat {
        min(tabWidth * 2, viewportWidth / 3)
    }

    internal func clamped(offset: CGFloat) -> CGFloat {
        min(max(offset, 0), maximumOffset)
    }

    // In content coordinates, the space the scroll view's document is laid out in.
    internal func frames(offset: CGFloat) -> [CGRect] {
        let origin = clamped(offset: offset)
        return (0 ..< count).map { index in
            let minX = position(ofSlotEdge: index, offset: origin)
            let maxX = position(ofSlotEdge: index + 1, offset: origin)
            return CGRect(
                x: minX,
                y: 0,
                width: maxX - minX,
                height: EditorTabStripLayout.tabHeight
            )
        }
    }

    // Where a point on the drawn run falls among the uniform slots a reorder resolves against.
    internal func slotLocation(ofContentX x: CGFloat, offset: CGFloat) -> CGFloat {
        let frames = frames(offset: offset)
        guard let first = frames.first, x > first.minX else { return 0 }
        guard let index = frames.firstIndex(where: { x < $0.maxX }) else { return contentWidth }
        let frame = frames[index]
        let fraction = frame.width > 0 ? (x - frame.minX) / frame.width : 0
        return (CGFloat(index) + fraction) * tabWidth
    }

    // The offset that shows a tab at full width, or the current one when it already does.
    internal func revealOffset(forTabAt index: Int, from offset: CGFloat) -> CGFloat {
        guard (0 ..< count).contains(index), maximumOffset > 0 else { return 0 }
        let origin = clamped(offset: offset)
        let minX = CGFloat(index) * tabWidth
        let maxX = minX + tabWidth
        if minX - origin < collapseZone {
            return clamped(offset: minX - collapseZone)
        }
        if maxX - origin > viewportWidth - collapseZone {
            return clamped(offset: maxX - viewportWidth + collapseZone)
        }
        return origin
    }

    private func position(ofSlotEdge edge: Int, offset: CGFloat) -> CGFloat {
        let visible = collapsed(CGFloat(edge) * tabWidth - offset, offset: offset)
        return (visible + offset).rounded()
    }

    private func collapsed(_ x: CGFloat, offset: CGFloat) -> CGFloat {
        let leading = min(offset, collapseZone)
        if x < leading {
            return leading - compressed(leading - x, into: leading, farthest: leading + offset)
        }
        let trailing = min(maximumOffset - offset, collapseZone)
        let edge = viewportWidth - trailing
        if x > edge {
            return edge + compressed(x - edge, into: trailing, farthest: contentWidth - offset - edge)
        }
        return x
    }

    // Starts at full scale, so no tab is drawn wider than its slot, and lands the farthest tab on the viewport's edge.
    private func compressed(_ distance: CGFloat, into zone: CGFloat, farthest: CGFloat) -> CGFloat {
        guard zone > 0, farthest > zone else { return min(distance, zone) }
        let scale = zone * farthest / (farthest - zone)
        return scale * distance / (distance + scale)
    }
}
