import AppKit
import SwiftUI

extension String {
    /// Parse this hex color string to NSColor (sRGB). Returns gray for invalid input.
    var nsColor: NSColor {
        let hex = trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))

        let hexLength = (hex as NSString).length
        guard hexLength == 6 || hexLength == 8 else {
            return .gray
        }

        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else {
            return .gray
        }

        let r, g, b, a: CGFloat

        if hexLength == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255.0
            g = CGFloat((value >> 16) & 0xFF) / 255.0
            b = CGFloat((value >> 8) & 0xFF) / 255.0
            a = CGFloat(value & 0xFF) / 255.0
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8) & 0xFF) / 255.0
            b = CGFloat(value & 0xFF) / 255.0
            a = 1.0
        }

        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Parse this hex color string to SwiftUI Color.
    var swiftUIColor: Color {
        Color(nsColor: nsColor)
    }

    /// Parse this hex color string to CGColor (sRGB).
    var cgColor: CGColor {
        nsColor.cgColor
    }
}

extension NSColor {
    /// Convert this NSColor to a hex string "#RRGGBB" or "#RRGGBBAA" (if alpha < 1).
    var hexString: String {
        guard let converted = usingColorSpace(.sRGB) else {
            return "#808080"
        }

        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)

        let ri = Int(round(r * 255))
        let gi = Int(round(g * 255))
        let bi = Int(round(b * 255))

        if a < 1.0 {
            let ai = Int(round(a * 255))
            return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
        }

        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}
