//
//  TagFilter.swift
//  CodeEditSourceEditor
//
//  Created by Roscoe Rubin-Rottenberg on 5/18/24.
//

import Foundation
import TextFormation
import TextStory
import CodeEditTextView
import CodeEditLanguages
import SwiftTreeSitter

struct TagFilter: Filter {
    enum Error: Swift.Error {
        case invalidLanguage
        case queryStringDataMissing
    }

    // HTML tags that self-close and should be ignored
    // https://developer.mozilla.org/en-US/docs/Glossary/Void_element
    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"
    ]

    var language: CodeLanguage
    var indentOption: IndentOption
    var lineEnding: LineEnding
    var treeSitterClient: TreeSitterClient

    func processMutation(
        _ mutation: TextMutation,
        in interface: TextInterface,
        with whitespaceProvider: WhitespaceProviders
    ) -> FilterAction {
        guard mutation.delta > 0 && mutation.range.location > 0 else { return .none }

        let prevCharRange = NSRange(location: mutation.range.location - 1, length: 1)
        guard interface.substring(from: prevCharRange) == ">" else {
            return .none
        }

        // Returns `nil` if it didn't find a valid start/end tag to complete.
        guard let mutationLen = handleInsertionAfterTag(mutation, in: interface, with: whitespaceProvider) else {
            return .none
        }

        // Do some extra processing if it's a newline.
        if mutation.string == lineEnding.rawValue {
            return handleNewlineInsertion(
                mutation,
                in: interface,
                with: whitespaceProvider,
                tagMutationLen: mutationLen
            )
        } else {
            return .none
        }
    }

    /// Handles inserting a character after a tag. Determining if the tag should be completed and inserting the correct
    /// closing tag string.
    /// - Parameters:
    ///   - mutation: The mutation causing the lookup.
    ///   - interface: The interface to retrieve text from.
    ///   - whitespaceProvider: The whitespace provider to use for indentation.
    /// - Returns: The length of the string inserted, if any string was inserted.
    private func handleInsertionAfterTag(
        _ mutation: TextMutation,
        in interface: TextInterface,
        with whitespaceProvider: WhitespaceProviders
    ) -> Int? {
        do {
            guard let startTag = try findTagPairs(mutation, in: interface) else { return nil }
            guard !Self.voidTags.contains(startTag) else { return nil }

            let closingTag = TextMutation(
                string: "</\(startTag)>",
                range: NSRange(location: mutation.range.max, length: 0),
                limit: interface.length
            )
            interface.applyMutation(closingTag)
            interface.selectedRange = NSRange(location: mutation.range.max, length: 0)
            return closingTag.string.utf16.count
        } catch {
            return nil
        }
    }

    // MARK: - tree-sitter Tree Querying

    /// Queries the tree-sitter syntax tree for necessary information for closing tags.
    /// - Parameters:
    ///   - mutation: The mutation causing the lookup.
    ///   - interface: The interface to retrieve text from.
    /// - Returns: A String representing the name of the start tag if found. If nil, abandon processing the tag.
    func findTagPairs(_ mutation: TextMutation, in interface: TextInterface) throws -> String? {
        // Find the tag name being completed.
        guard let (foundStartTag, queryResult) = try getOpeningTagName(mutation, in: interface) else {
            return nil
        }
        // Perform a query searching for the same tag, summing up opening and closing tags
        let openQuery = try tagQuery(
            queryResult.language,
            id: queryResult.id,
            tagName: foundStartTag,
            opening: true,
            openingTagId: queryResult.node.parent?.nodeType
        )
        let closeQuery = try tagQuery(
            queryResult.language,
            id: queryResult.id,
            tagName: foundStartTag,
            opening: false,
            openingTagId: queryResult.node.parent?.nodeType
        )

        let openTags = try treeSitterClient.query(openQuery, matchingLanguages: [.html, .jsx, .tsx])
            .flatMap { $0.cursor.flatMap { $0.captures(named: "name") } }
        let closeTags = try treeSitterClient.query(closeQuery, matchingLanguages: [.html, .jsx, .tsx])
            .flatMap { $0.cursor.flatMap { $0.captures(named: "name") } }

        if openTags.count > closeTags.count {
            return foundStartTag
        } else {
            return nil
        }
    }

    /// Build a query getting all matching tags for either opening or closing tags.
    /// - Parameters:
    ///   - language: The language to query.
    ///   - id: The ID of the language.
    ///   - tagName: The name of the tag to query for.
    ///   - opening: True, if this should be querying for an opening tag.
    ///   - openingTagId: The ID of the opening tag if exists.
    /// - Returns: A query to execute on a tree sitter tree, finding all matching nodes.
    private func tagQuery(
        _ language: Language,
        id: TreeSitterLanguage,
        tagName: String,
        opening: Bool,
        openingTagId: String?
    ) throws -> Query {
        let tagId = try tagId(for: id, opening: opening, openingTag: openingTagId)
        let tagNameContents: String = try tagNameId(for: id)
        let queryString = ("((" + tagId + " (" + tagNameContents + #") @name) (#eq? @name ""# + tagName + #""))"#)
        guard let queryData = queryString.data(using: .utf8) else {
            throw Self.Error.queryStringDataMissing
        }
        return try Query(language: language, data: queryData)
    }

    /// Get the node ID for a tag in a language.
    /// - Parameters:
    ///   - id: The language to get the ID for.
    ///   - opening: True, if querying the opening tag.
    ///   - openingTag: The ID of the original opening tag.
    /// - Returns: The node ID for the given language and whether or not it's an opening or closing tag.
    private func tagId(for id: TreeSitterLanguage, opening: Bool, openingTag: String?) throws -> String {
        switch id {
        case .html:
            if opening {
                return "start_tag"
            } else {
                return "end_tag"
            }
        case .jsx, .tsx:
            if opening {
                // Opening tag, match the given opening tag.
                return openingTag ?? (id == .jsx ? "jsx_opening_element" : "tsx_opening_element")
            } else if let openingTag {
                // Closing tag, match the opening tag ID.
                if openingTag == "jsx_opening_element" {
                    return "jsx_closing_element"
                } else {
                    return "tsx_closing_element"
                }
            } else {
                throw Self.Error.invalidLanguage
            }
        default:
            throw Self.Error.invalidLanguage
        }
    }

    /// Get possible node IDs for a tag in a language.
    /// - Parameters:
    ///   - id: The language to get the ID for.
    ///   - opening: True, if querying the opening tag.
    /// - Returns: A set of possible node IDs for the language.
    private func tagIds(for id: TreeSitterLanguage, opening: Bool) throws -> Set<String> {
        switch id {
        case .html:
            return [opening ? "start_tag" : "end_tag"]
        case .jsx, .tsx:
            return [
                opening ? "jsx_opening_element" : "jsx_closing_element",
                opening ? "tsx_opening_element" : "tsx_closing_element"
            ]
        default:
            throw Self.Error.invalidLanguage
        }
    }

    /// Get the name of the node that contains the tag's name.
    /// - Parameter id: The language to get the name for.
    /// - Returns: The node ID for a node that contains the tag's name.
    private func tagNameId(for id: TreeSitterLanguage) throws -> String {
        switch id {
        case .html:
            return "tag_name"
        case .jsx, .tsx:
            return "identifier"
        default:
            throw Self.Error.invalidLanguage
        }
    }

    /// Gets the name of the opening tag to search for.
    /// - Parameters:
    ///   - mutation: The mutation causing the search.
    ///   - interface: The interface to use for text content.
    /// - Returns: The tag's name and the range of the matching node, if found.
    private func getOpeningTagName(
        _ mutation: TextMutation,
        in interface: TextInterface
    ) throws -> (String, TreeSitterClient.NodeResult)? {
        let prevCharRange = NSRange(location: mutation.range.location - 1, length: 1)
        let nodesAtLocation = try treeSitterClient.nodesAt(location: mutation.range.location - 1)
        var foundStartTag: (String, TreeSitterClient.NodeResult)?

        for result in nodesAtLocation {
            // Only attempt to process layers with the correct language.
            guard result.id.shouldProcessTags() else { continue }
            let tagIds = try tagIds(for: result.id, opening: true)
            let tagNameId = try tagNameId(for: result.id)
            // This node should represent the ">" character, grab its parent (the start tag node).
            guard let node = result.node.parent else { continue }
            guard node.byteRange.upperBound == UInt32(prevCharRange.max * 2),
                  tagIds.contains(node.nodeType ?? ""),
                  let tagNameNode = node.firstChild(where: { $0.nodeType == tagNameId }),
                  let tagName = interface.substring(from: tagNameNode.range)
            else {
                continue
            }

            foundStartTag = (
                tagName,
                result
            )
        }

        return foundStartTag
    }

    // MARK: - Newline Processing

    /// Processes a newline mutation, inserting the necessary newlines and indents after a tag closure.
    /// Also places the selection position to the indented spot.
    ///
    /// Causes this interaction (where | is the cursor end location, X is the original location, and div was the tag
    /// being completed):
    /// ```html
    ///   <div>X
    ///     |
    ///   </div>
    /// ```
    ///
    /// - Note: Must be called **after** the closing tag is inserted.
    /// - Parameters:
    ///   - mutation: The mutation to process.
    ///   - interface: The interface to modify.
    ///   - whitespaceProvider: Provider used for getting whitespace from the interface.
    ///   - tagMutationLen: The length of the inserted tag mutation.
    /// - Returns: The action to take for this mutation.
    private func handleNewlineInsertion(
        _ mutation: TextMutation,
        in interface: TextInterface,
        with whitespaceProvider: WhitespaceProviders,
        tagMutationLen: Int
    ) -> FilterAction {
        guard let whitespaceRange = mutation.range.shifted(by: tagMutationLen + lineEnding.rawValue.utf16.count) else {
            return .none
        }
        let whitespace = whitespaceProvider.leadingWhitespace(whitespaceRange, interface)

        // Should end up with (where | is the cursor and div was the tag being completed):
        // <div>
        //     |
        // </div>
        let string = lineEnding.rawValue + whitespace + indentOption.stringValue + lineEnding.rawValue + whitespace
        interface.insertString(string, at: mutation.range.max)
        let offsetFromMutation = lineEnding.length + whitespace.utf16.count + indentOption.stringValue.utf16.count
        interface.selectedRange = NSRange(location: mutation.range.max + offsetFromMutation, length: 0)

        return .discard
    }
}
