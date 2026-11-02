//
//  ResizableEditorContainer.swift
//  TablePro
//

import SwiftUI

internal struct ResizableEditorContainer<Content: View>: View {
    let column: String
    let defaultHeight: Double
    let range: ClosedRange<Double>
    // Wins over the dragged height without overwriting it, so collapsing returns to the user's size.
    var expandedHeight: Double?
    @ObservedObject var heights: InspectorFieldHeightStore
    @ViewBuilder let content: () -> Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var liveDelta: Double = 0

    init(
        column: String,
        defaultHeight: Double,
        range: ClosedRange<Double>,
        expandedHeight: Double? = nil,
        heights: InspectorFieldHeightStore = .shared,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.column = column
        self.defaultHeight = defaultHeight
        self.range = range
        self.expandedHeight = expandedHeight
        self.heights = heights
        self.content = content
    }

    private var baseHeight: Double {
        heights.height(for: column) ?? defaultHeight
    }

    private var resolvedHeight: Double {
        let dragged = ResizableFieldMetrics.resolve(base: baseHeight, delta: liveDelta, range: range)
        // The ranges reach 600, so a field dragged past the expanded height must not shrink on Expand.
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
        .onChange(of: isEnabled) { enabled in
            if !enabled { liveDelta = 0 }
        }
    }

    private var resizeHandle: some View {
        FieldResizeHandle(
            onDrag: { liveDelta = $0 },
            onEnd: { delta in
                if let height = ResizableFieldMetrics.committedHeight(base: baseHeight, delta: delta, range: range) {
                    heights.setHeight(height, for: column)
                }
                liveDelta = 0
            }
        )
        .frame(maxWidth: .infinity)
        .frame(height: 11)
        .onDisappear { liveDelta = 0 }
        .accessibilityHidden(true)
    }
}
