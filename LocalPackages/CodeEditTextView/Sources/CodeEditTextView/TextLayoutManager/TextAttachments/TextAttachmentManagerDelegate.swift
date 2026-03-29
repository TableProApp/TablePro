//
//  TextAttachmentManagerDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/25/25.
//

import Foundation

public protocol TextAttachmentManagerDelegate: AnyObject {
    func textAttachmentDidAdd(_ attachment: any TextAttachment, for range: NSRange)
    func textAttachmentDidRemove(_ attachment: any TextAttachment, for range: NSRange)
}
