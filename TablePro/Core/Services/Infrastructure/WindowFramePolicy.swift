//
//  WindowFramePolicy.swift
//  TablePro
//

import AppKit
import Foundation

internal struct WindowFramePolicy: Sendable {
    let autosaveName: NSWindow.FrameAutosaveName
    let fullScreenStateKey: String
    let firstRunSizing: FirstRunSizing
}

internal extension WindowFramePolicy {
    enum FirstRunSizing: Sendable {
        case preserveContentSize
        case fractionOfMainScreen(fraction: CGSize, minimum: NSSize, maximum: NSSize?)

        func contentSize(for screenFrame: NSRect) -> NSSize? {
            switch self {
            case .preserveContentSize:
                return nil
            case let .fractionOfMainScreen(fraction, minimum, maximum):
                let proposedWidth = screenFrame.width * fraction.width
                let proposedHeight = screenFrame.height * fraction.height

                let minClampedWidth = max(proposedWidth, minimum.width)
                let minClampedHeight = max(proposedHeight, minimum.height)

                let maxWidth = min(maximum?.width ?? .greatestFiniteMagnitude, screenFrame.width)
                let maxHeight = min(maximum?.height ?? .greatestFiniteMagnitude, screenFrame.height)

                let width = min(minClampedWidth, maxWidth)
                let height = min(minClampedHeight, maxHeight)
                return NSSize(width: width.rounded(), height: height.rounded())
            }
        }
    }

    static let editor = WindowFramePolicy(
        autosaveName: "MainEditorWindow",
        fullScreenStateKey: "com.TablePro.windowState.editor.isFullScreen",
        firstRunSizing: .fractionOfMainScreen(
            fraction: CGSize(width: 0.85, height: 0.85),
            minimum: NSSize(width: 1_200, height: 800),
            maximum: nil
        )
    )

    static let jsonViewer = WindowFramePolicy(
        autosaveName: "JSONViewerWindow",
        fullScreenStateKey: "com.TablePro.windowState.jsonViewer.isFullScreen",
        firstRunSizing: .fractionOfMainScreen(
            fraction: CGSize(width: 0.45, height: 0.55),
            minimum: NSSize(width: 640, height: 500),
            maximum: NSSize(width: 1_100, height: 900)
        )
    )

    static let integrationsActivity = WindowFramePolicy(
        autosaveName: "IntegrationsActivityWindow",
        fullScreenStateKey: "com.TablePro.windowState.integrationsActivity.isFullScreen",
        firstRunSizing: .fractionOfMainScreen(
            fraction: CGSize(width: 0.55, height: 0.65),
            minimum: NSSize(width: 960, height: 600),
            maximum: NSSize(width: 1_400, height: 1_000)
        )
    )

    static let feedback = WindowFramePolicy(
        autosaveName: "FeedbackWindow",
        fullScreenStateKey: "com.TablePro.windowState.feedback.isFullScreen",
        firstRunSizing: .preserveContentSize
    )
}
