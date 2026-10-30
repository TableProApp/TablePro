//
//  AboutPanelCredits.swift
//  TablePro
//

import AppKit
import os

/// The About panel's credits: the project links, then the license holders who asked to be thanked
/// by name.
enum AboutPanelCredits {
    static func attributedString(supporters: [String] = SupporterList.load()) -> NSAttributedString {
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let credits = NSMutableAttributedString()
        let links: [(String, String)] = [
            ("Website", MainMenuLink.website),
            ("GitHub", MainMenuLink.repository),
            (String(localized: "Documentation"), MainMenuLink.documentation),
            (String(localized: "Sponsor"), SupportLinks.sponsors(.aboutPanel).absoluteString)
        ]
        for (index, link) in links.enumerated() {
            if index > 0 {
                credits.append(NSAttributedString(string: "  |  ", attributes: style))
            }
            let attributed = NSMutableAttributedString(string: link.0, attributes: style)
            if let url = URL(string: link.1) {
                attributed.addAttribute(.link, value: url, range: NSRange(location: 0, length: attributed.length))
            }
            credits.append(attributed)
        }

        if !supporters.isEmpty {
            let heading = String(localized: "Thanks to these license holders")
            credits.append(NSAttributedString(string: "\n\n\(heading)\n", attributes: style))
            credits.append(NSAttributedString(string: supporters.joined(separator: ", "), attributes: style))
        }

        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        return credits
    }
}

/// License holders who asked, by email, to be named in the About panel.
///
/// `Supporters.json` in the app's resources is the only copy of the list. A name goes in, or comes
/// out, through a pull request, and only after its owner said yes, using the spelling they gave.
enum SupporterList {
    static let resourceName = "Supporters"

    private struct File: Decodable {
        let supporters: [String]
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "SupporterList")

    static func load(from bundle: Bundle = .main) -> [String] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            logger.error("Supporters.json is missing from the app bundle")
            return []
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            logger.error("Could not read Supporters.json: \(error.publicLogShape, privacy: .public)")
            return []
        }
    }

    static func decode(_ data: Data) throws -> [String] {
        try JSONDecoder().decode(File.self, from: data).supporters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
