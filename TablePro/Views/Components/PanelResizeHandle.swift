//
//  PanelResizeHandle.swift
//  TablePro
//
//  Draggable resize handle for the right panel.
//

import SwiftUI

struct PanelResizeHandle: View {
    @Binding var panelWidth: CGFloat

    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        // Dragging left increases panel width (handle is on the leading edge)
                        let newWidth = panelWidth - value.translation.width
                        panelWidth = min(max(newWidth, RightPanelState.minWidth), RightPanelState.maxWidth)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}
