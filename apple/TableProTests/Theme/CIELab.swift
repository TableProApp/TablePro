import Foundation
import TableProTheme

// CIEDE2000 (Sharma, Wu and Dalal, 2005). Unlike a WCAG ratio it counts hue: macOS's pale blue selection on white is 1.49:1 yet 18 apart.
struct CIELab {
    let lightness: Double
    let aStar: Double
    let bStar: Double

    init(lightness: Double, aStar: Double, bStar: Double) {
        self.lightness = lightness
        self.aStar = aStar
        self.bStar = bStar
    }

    // sRGB under D65; alpha is ignored, so composite first.
    init(_ color: ThemeColor) {
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let red = linear(color.red)
        let green = linear(color.green)
        let blue = linear(color.blue)
        let x = (0.4124 * red + 0.3576 * green + 0.1805 * blue) / 0.95047
        let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let z = (0.0193 * red + 0.1192 * green + 0.9505 * blue) / 1.08883
        func curve(_ value: Double) -> Double {
            value > 0.008856 ? cbrt(value) : 7.787 * value + 16.0 / 116.0
        }
        lightness = 116 * curve(y) - 16
        aStar = 500 * (curve(x) - curve(y))
        bStar = 200 * (curve(y) - curve(z))
    }

    func difference(from other: CIELab) -> Double {
        let chromaMean = (hypot(aStar, bStar) + hypot(other.aStar, other.bStar)) / 2
        let chromaWeight = 0.5 * (1 - (pow(chromaMean, 7) / (pow(chromaMean, 7) + pow(25, 7))).squareRoot())
        let primeA1 = (1 + chromaWeight) * aStar
        let primeA2 = (1 + chromaWeight) * other.aStar
        let chroma1 = hypot(primeA1, bStar)
        let chroma2 = hypot(primeA2, other.bStar)
        let hue1 = Self.degrees(atan2(bStar, primeA1))
        let hue2 = Self.degrees(atan2(other.bStar, primeA2))

        let deltaLightness = other.lightness - lightness
        let deltaChroma = chroma2 - chroma1
        var deltaHueAngle = 0.0
        if chroma1 * chroma2 != 0 {
            deltaHueAngle = hue2 - hue1
            if deltaHueAngle > 180 { deltaHueAngle -= 360 } else if deltaHueAngle < -180 { deltaHueAngle += 360 }
        }
        let deltaHue = 2 * (chroma1 * chroma2).squareRoot() * sin(Self.radians(deltaHueAngle / 2))

        let lightnessMean = (lightness + other.lightness) / 2
        let primeChromaMean = (chroma1 + chroma2) / 2
        var hueMean = hue1 + hue2
        if chroma1 * chroma2 != 0 {
            if abs(hue1 - hue2) <= 180 {
                hueMean /= 2
            } else {
                hueMean = hueMean < 360 ? (hueMean + 360) / 2 : (hueMean - 360) / 2
            }
        }
        let hueTerm = 1
            - 0.17 * cos(Self.radians(hueMean - 30))
            + 0.24 * cos(Self.radians(2 * hueMean))
            + 0.32 * cos(Self.radians(3 * hueMean + 6))
            - 0.20 * cos(Self.radians(4 * hueMean - 63))
        let rotationAngle = 30 * exp(-pow((hueMean - 275) / 25, 2))
        let chromaRotation = 2 * (pow(primeChromaMean, 7) / (pow(primeChromaMean, 7) + pow(25, 7))).squareRoot()
        let lightnessScale = 1 + 0.015 * pow(lightnessMean - 50, 2) / (20 + pow(lightnessMean - 50, 2)).squareRoot()
        let chromaScale = 1 + 0.045 * primeChromaMean
        let hueScale = 1 + 0.015 * primeChromaMean * hueTerm
        let rotation = -sin(Self.radians(2 * rotationAngle)) * chromaRotation

        let lightnessPart = deltaLightness / lightnessScale
        let chromaPart = deltaChroma / chromaScale
        let huePart = deltaHue / hueScale
        return (lightnessPart * lightnessPart + chromaPart * chromaPart + huePart * huePart + rotation * chromaPart * huePart)
            .squareRoot()
    }

    private static func degrees(_ radians: Double) -> Double {
        let value = radians * 180 / .pi
        return value < 0 ? value + 360 : value
    }

    private static func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}

extension ThemeColor {
    func perceptualDifference(from other: ThemeColor) -> Double {
        CIELab(self).difference(from: CIELab(other))
    }
}
