// By scalar: a quote that a combining mark follows is one Character, and a Character search misses it.
public enum ShellQuoting {
    public static func singleQuoted(_ value: String) throws -> String {
        var quoted = String.UnicodeScalarView()
        quoted.append("'")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\0": throw ProcessLaunchError.nulCharacter
            case "'": quoted.append(contentsOf: #"'\''"#.unicodeScalars)
            default: quoted.append(scalar)
            }
        }
        quoted.append("'")
        return String(quoted)
    }

    // One argument as a person reads it: bare when nothing in it hides where it ends, and in `$'…'` with
    // escapes when it holds a control or format character that would hide or reorder text.
    public static func displayWord(_ value: String) -> String {
        if !value.isEmpty, value.unicodeScalars.allSatisfy(isPlain) { return value }
        guard value.unicodeScalars.contains(where: isInvisible) else {
            return (try? singleQuoted(value)) ?? escapedWord(value)
        }
        return escapedWord(value)
    }

    private static func escapedWord(_ value: String) -> String {
        var word = "$'"
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": word += #"\\"#
            case "'": word += #"\'"#
            // Bytes, since macOS's bash 3.2 reads `\xHH` in `$'…'` but not `\u`.
            case _ where isInvisible(scalar):
                for byte in String(scalar).utf8 {
                    word += "\\x" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
                }
            default: word.unicodeScalars.append(scalar)
            }
        }
        return word + "'"
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "@", "%", "_", "+", "=", ":", ",", ".", "/", "-": true
        default: false
        }
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .privateUse, .surrogate: true
        default: false
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
