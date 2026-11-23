//
//  ViewReuseQueue.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 8/14/23.
//

import AppKit
import DequeModule

/// Maintains a queue of views available for reuse.
public class ViewReuseQueue<View: NSView, Key: Hashable> {
    /// A stack of views that are not currently in use
    public var queuedViews: Deque<View> = []

    /// Maps views that are no longer queued to the keys they're queued with.
    public var usedViews: [Key: View] = [:]

    public init() { }

    /// Finds, dequeues, or creates a view for the given key.
    ///
    /// If the view has been dequeued, it will return the view already queued for the given key it will be returned.
    /// If there was no view dequeued for the given key, the returned view will either be a view queued for reuse or a
    /// new view object.
    ///
    /// - Parameters:
    ///   - key: The key for the view to find.
    ///   - createView: A callback that is called to create a new instance of the queued view types.
    /// - Returns: A view for the given key.
    public func getOrCreateView(forKey key: Key, createView: () -> View) -> View {
        let view: View
        if let usedView = usedViews[key] {
            view = usedView
        } else {
            view = queuedViews.popFirst() ?? createView()
            view.prepareForReuse()
            view.isHidden = false
            usedViews[key] = view
        }
        return view
    }

    public func getView(forKey key: Key) -> View? {
        usedViews[key]
    }

    // A queued view stays a hidden subview, so the queue keeps no more views than the pass left in use. Bounded by
    // the views in use while they are still being released, a pass that drops most of them kept half.
    public func enqueueViews(notInSet keys: Set<Key>) {
        let released = usedViews.keys.filter { !keys.contains($0) }
        let capacity = usedViews.count - released.count
        for key in released {
            guard let view = usedViews.removeValue(forKey: key) else { continue }
            if queuedViews.count < capacity {
                queuedViews.append(view)
                view.frame = .zero
                view.isHidden = true
            } else {
                view.removeFromSuperviewWithoutNeedingDisplay()
            }
        }
        while queuedViews.count > capacity, let view = queuedViews.popLast() {
            view.removeFromSuperviewWithoutNeedingDisplay()
        }
    }

    deinit {
        usedViews.removeAll()
        queuedViews.removeAll()
    }
}
