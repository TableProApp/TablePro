//
//  EmphasisToolTips.swift
//  CodeEditTextView
//

import AppKit

final class EmphasisToolTips: NSObject, NSViewToolTipOwner {
    private struct Registration {
        let text: String
        let rects: [CGRect]
        let tags: [NSView.ToolTipTag]
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]

    func register(_ text: String?, rects: [CGRect], for layer: CALayer, in view: NSView?) {
        let key = ObjectIdentifier(layer)
        if let existing = registrations[key], existing.text == text, existing.rects == rects {
            return
        }
        unregister(layer, in: view)
        guard let view, let text, !text.isEmpty, !rects.isEmpty else { return }

        let tags = rects.map { view.addToolTip($0, owner: self, userData: nil) }
        registrations[key] = Registration(text: text, rects: rects, tags: tags)
    }

    func unregister(_ layer: CALayer, in view: NSView?) {
        guard let registration = registrations.removeValue(forKey: ObjectIdentifier(layer)) else { return }
        registration.tags.forEach { view?.removeToolTip($0) }
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        registrations.values.first { registration in
            registration.rects.contains { $0.contains(point) }
        }?.text ?? ""
    }
}
