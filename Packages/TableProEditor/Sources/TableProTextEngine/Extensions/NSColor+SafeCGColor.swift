import AppKit

public extension NSColor {
    /// Converts to a concrete color space before accessing `.cgColor`.
    /// Avoids macOS 26 crash where dynamic/catalog colors go through deprecated `colorSpaceName`.
    var safeCGColor: CGColor {
        if let srgb = usingColorSpace(.sRGB) {
            return srgb.cgColor
        }
        if let deviceRGB = usingColorSpace(.deviceRGB) {
            return deviceRGB.cgColor
        }
        return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
    }
}
