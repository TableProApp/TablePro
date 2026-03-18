//
//  JumpToDefinitionDelegate.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/23/25.
//

import Foundation

public protocol JumpToDefinitionDelegate: AnyObject {
    func queryLinks(forRange range: NSRange, textView: TextViewController) async -> [JumpToDefinitionLink]?
    func openLink(link: JumpToDefinitionLink)
}
