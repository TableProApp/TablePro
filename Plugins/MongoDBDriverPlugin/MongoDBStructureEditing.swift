//
//  MongoDBStructureEditing.swift
//  MongoDBDriverPlugin
//

import Foundation

/// What the Structure tab can change on a collection: a field's name, carried out on every document
/// that holds it, and the field's removal. A field is added by writing it to a document, and index
/// changes stay in the shell, because the index list the tab shows does not carry the key order or
/// the index type a recreated index would need.
///
/// Kept apart from `MongoDBPlugin` so the app's curated copy of these flags can be compared with
/// them in tests, which cannot compile the plugin class and the driver it creates.
enum MongoDBStructureEditing {
    static let supportsSchemaEditing = true
    static let supportsAddColumn = false
    static let supportsModifyColumn = true
    static let supportsDropColumn = true
    static let supportsAddIndex = false
    static let supportsDropIndex = false
}
