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

    /// A layer keeps the value it is handed, so a system color going into one is resolved for the appearance its view
    /// draws in, never for whatever appearance happens to be current.
    func safeCGColor(in appearance: NSAppearance) -> CGColor {
        var result: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            result = self.safeCGColor
        }
        return result ?? safeCGColor
    }

    /// The fixed value of a system color in an appearance, for drawing that runs outside AppKit's own drawing pass,
    /// such as a `CATextLayer`.
    func resolved(in appearance: NSAppearance) -> NSColor {
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = self.usingColorSpace(.sRGB)
        }
        return result ?? self
    }
}
