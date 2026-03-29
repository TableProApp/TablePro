//
//  TextAttachment.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/24/25.
//

import AppKit

public enum TextAttachmentAction {
    /// Perform no action.
    case none
    /// Replace the attachment range with the given string.
    case replace(text: String)
    /// Discard the attachment and perform no other action, this is the default action.
    case discard
}

/// Represents an attachment type. Attachments take up some set width, and draw their contents in a receiver view.
public protocol TextAttachment: AnyObject {
    var width: CGFloat { get }
    var isSelected: Bool { get set }

    func draw(in context: CGContext, rect: NSRect)

    /// The action that should be performed when this attachment is invoked (double-click, enter pressed).
    /// This method is optional, by default the attachment is discarded.
    func attachmentAction() -> TextAttachmentAction
}

public extension TextAttachment {
    func attachmentAction() -> TextAttachmentAction { .discard }
}

/// Type-erasing type for ``TextAttachment`` that also contains range information about the attachment.
///
/// This type cannot be initialized outside of `CodeEditTextView`, but will be received when interrogating
/// the ``TextAttachmentManager``.
public struct AnyTextAttachment: Equatable {
    package(set) public var range: NSRange
    public let attachment: any TextAttachment

    var width: CGFloat {
        attachment.width
    }

    public static func == (_ lhs: AnyTextAttachment, _ rhs: AnyTextAttachment) -> Bool {
        lhs.range == rhs.range && lhs.attachment === rhs.attachment
    }
}
