//
//  ViewReuseQueue.swift
//  CodeEditTextView
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

    /// Removes a view for the given key and enqueues it for reuse.
    /// - Parameter key: The key for the view to reuse.
    public func enqueueView(forKey key: Key) {
        guard let view = usedViews[key] else { return }
        if queuedViews.count < usedViews.count {
            queuedViews.append(view)
            view.frame = .zero
            view.isHidden = true
        } else {
            view.removeFromSuperviewWithoutNeedingDisplay()
        }
        usedViews.removeValue(forKey: key)
    }

    /// Enqueues all views not in the given set.
    /// - Parameter outsideSet: The keys who's views should not be enqueued for reuse.
    public func enqueueViews(notInSet keys: Set<Key>) {
        // Get all keys that are currently in "use" but not in the given set, and enqueue them for reuse.
        for key in Set(usedViews.keys).subtracting(keys) {
            enqueueView(forKey: key)
        }
    }

    /// Enqueues all views keyed by the given set.
    /// - Parameter keys: The keys for all the views that should be enqueued.
    public func enqueueViews(in keys: Set<Key>) {
        for key in keys {
            enqueueView(forKey: key)
        }
    }

    deinit {
        usedViews.removeAll()
        queuedViews.removeAll()
    }
}
