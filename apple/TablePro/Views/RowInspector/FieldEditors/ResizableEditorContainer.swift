//
//  ResizableEditorContainer.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct ResizableEditorContainer<Content: View>: View {
    @Binding var height: Double
    let range: ClosedRange<Double>

    /// Set while the field is expanded in place. It wins over the dragged height for as long as it
    /// lasts and never overwrites it, so collapsing returns the editor to the size the user chose.
    var expandedHeight: Double?

    @ViewBuilder let content: () -> Content

    @State private var liveDelta: Double = 0
    @State private var isHandleHovered = false

    private var resolvedHeight: Double {
        let dragged = ResizableFieldMetrics.resolve(base: height, delta: liveDelta, range: range)
        /// Never below what the user already dragged. The allowed ranges reach 600, so a field
        /// enlarged past the expanded height would otherwise shrink when asked to expand.
        if let expandedHeight { return max(expandedHeight, dragged) }
        return dragged
    }

    var body: some View {
        VStack(spacing: 2) {
            content()
                .frame(height: resolvedHeight)
            if expandedHeight == nil {
                resizeHandle
            }
        }
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(Color(nsColor: .tertiaryLabelColor))
            .frame(width: 26, height: 4)
            .opacity(isHandleHovered ? 1 : 0.5)
            .frame(maxWidth: .infinity, minHeight: 11)
            .overlay {
                FieldResizeHandle(
                    onHover: { isHandleHovered = $0 },
                    onDrag: { liveDelta = $0 },
                    onEnd: { delta in
                        height = ResizableFieldMetrics.resolve(base: height, delta: delta, range: range)
                        liveDelta = 0
                    }
                )
            }
            .accessibilityHidden(true)
    }
}
