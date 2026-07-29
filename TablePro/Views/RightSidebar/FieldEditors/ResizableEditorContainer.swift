//
//  ResizableEditorContainer.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct ResizableEditorContainer<Content: View>: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    @ViewBuilder let content: () -> Content

    @GestureState private var liveDelta: Double = 0
    @State private var isHandleHovered = false

    private var resolvedHeight: Double {
        ResizableFieldMetrics.resolve(base: height, delta: liveDelta, range: range)
    }

    var body: some View {
        VStack(spacing: 2) {
            content()
                .frame(height: resolvedHeight)
            resizeHandle
        }
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(Color(nsColor: .tertiaryLabelColor))
            .frame(width: 26, height: 4)
            .opacity(isHandleHovered ? 1 : 0.5)
            .frame(maxWidth: .infinity, minHeight: 11)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($liveDelta) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        height = ResizableFieldMetrics.resolve(
                            base: height,
                            delta: value.translation.height,
                            range: range
                        )
                    }
            )
            .onHover { hovering in
                guard hovering != isHandleHovered else { return }
                isHandleHovered = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHandleHovered {
                    NSCursor.pop()
                    isHandleHovered = false
                }
            }
            .accessibilityHidden(true)
    }
}
