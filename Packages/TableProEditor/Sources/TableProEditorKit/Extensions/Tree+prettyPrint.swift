//
//  Tree+prettyPrint.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 3/16/23.
//

import SwiftTreeSitter

#if DEBUG
extension Tree {
    func prettyPrint() {
        guard let cursor = self.rootNode?.treeCursor else {
            print("NO ROOT NODE")
            return
        }
        guard cursor.currentNode != nil else {
            print("NO CURRENT NODE")
            return
        }

        func p(_ cursor: TreeCursor, depth: Int) {
            guard let node = cursor.currentNode else {
                return
            }

            let visible = node.isNamed

            if visible {
                print(String(repeating: " ", count: depth * 2), terminator: "")
                if let fieldName = cursor.currentFieldName {
                    print(fieldName, ": ", separator: "", terminator: "")
                }
                print("(", node.nodeType ?? "NONE", " ", node.range, " ", separator: "", terminator: "")
            }

            if cursor.goToFirstChild() {
                while true {
                    if cursor.currentNode?.isNamed == true {
                        print("")
                    }

                    p(cursor, depth: depth + 1)

                    if !cursor.gotoNextSibling() {
                        break
                    }
                }

                if !cursor.gotoParent() {
                    fatalError("Could not go to parent, this tree may be invalid.")
                }
            }

            if visible {
                print(")", terminator: depth == 1 ? "\n" : "")
            }
        }

        if let node = cursor.currentNode, node.childCount == 0 {
            let nodeType = node.nodeType ?? "NONE"
            print(node.isNamed ? "\"\(nodeType)\"" : "{\(nodeType)}")
        } else {
            p(cursor, depth: 1)
        }
    }
}

extension MutableTree {
    func prettyPrint() {
        guard let cursor = self.rootNode?.treeCursor else {
            print("NO ROOT NODE")
            return
        }
        guard cursor.currentNode != nil else {
            print("NO CURRENT NODE")
            return
        }

        func p(_ cursor: TreeCursor, depth: Int) {
            guard let node = cursor.currentNode else {
                return
            }

            let visible = node.isNamed

            if visible {
                print(String(repeating: " ", count: depth * 2), terminator: "")
                if let fieldName = cursor.currentFieldName {
                    print(fieldName, ": ", separator: "", terminator: "")
                }
                print("(", node.nodeType ?? "NONE", " ", node.range, " ", separator: "", terminator: "")
            }

            if cursor.goToFirstChild() {
                while true {
                    if cursor.currentNode?.isNamed == true {
                        print("")
                    }

                    p(cursor, depth: depth + 1)

                    if !cursor.gotoNextSibling() {
                        break
                    }
                }

                if !cursor.gotoParent() {
                    fatalError("Could not go to parent, this tree may be invalid.")
                }
            }

            if visible {
                print(")", terminator: depth == 1 ? "\n" : "")
            }
        }

        if let node = cursor.currentNode, node.childCount == 0 {
            let nodeType = node.nodeType ?? "NONE"
            print(node.isNamed ? "\"\(nodeType)\"" : "{\(nodeType)}")
        } else {
            p(cursor, depth: 1)
        }
    }
}
#endif
