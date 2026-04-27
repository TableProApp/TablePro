import AppKit

extension NSColor {
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
