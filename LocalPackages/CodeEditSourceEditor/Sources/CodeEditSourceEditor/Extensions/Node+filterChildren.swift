//
//  Node+filterChildren.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/29/24.
//

import SwiftTreeSitter

extension Node {
    func firstChild(`where` isMatch: (Node) -> Bool) -> Node? {
        for idx in 0..<childCount {
            guard let node = child(at: idx) else { continue }
            if isMatch(node) {
                return node
            }
        }

        return nil
    }

    func mapChildren<T>(_ callback: (Node) -> T) -> [T] {
        var retVal: [T] = []
        for idx in 0..<childCount {
            guard let node = child(at: idx) else { continue }
            retVal.append(callback(node))
        }
        return retVal
    }

    func filterChildren(_ isIncluded: (Node) -> Bool) -> [Node] {
        var retVal: [Node] = []
        for idx in 0..<childCount {
            guard let node = child(at: idx) else { continue }
            if isIncluded(node) {
                retVal.append(node)
            }
        }

        return retVal
    }
}
