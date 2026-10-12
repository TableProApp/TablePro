import Foundation

public enum TabularJISRoman {
    private static let yenSign: Unicode.Scalar = "\u{A5}"
    private static let overline: Unicode.Scalar = "\u{203E}"

    public static func folded(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == yenSign || $0 == overline }) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case yenSign: scalars.append("\\")
            case overline: scalars.append("~")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
