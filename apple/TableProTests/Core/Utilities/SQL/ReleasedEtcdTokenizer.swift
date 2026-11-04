import Foundation

// The tokenizer the 0.84.0 and 0.85.0-beta.1 hosts compile into their etcd classifier, kept as it shipped. An
// updated registry driver runs on those hosts, so its commands, flags and names must read the same words.
enum ReleasedEtcdTokenizer {
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        var inQuote = false
        var quoteScalar: Unicode.Scalar = "\""
        var escapeNext = false
        var tokenStarted = false

        for scalar in input.unicodeScalars {
            if escapeNext {
                tokenStarted = true
                if inQuote {
                    switch scalar {
                    case "n": current.append("\n")
                    case "r": current.append("\r")
                    case "t": current.append("\t")
                    case "\\": current.append("\\")
                    case "\"": current.append("\"")
                    case "'": current.append("'")
                    default:
                        current.append("\\")
                        current.append(scalar)
                    }
                } else {
                    current.append("\\")
                    current.append(scalar)
                }
                escapeNext = false
                continue
            }

            if scalar == "\\" {
                if inQuote {
                    escapeNext = true
                } else {
                    current.append(scalar)
                    tokenStarted = true
                }
                continue
            }

            if inQuote {
                if scalar == quoteScalar {
                    inQuote = false
                    tokenStarted = true
                } else {
                    current.append(scalar)
                    tokenStarted = true
                }
                continue
            }

            if scalar == "\"" || scalar == "'" {
                inQuote = true
                quoteScalar = scalar
                tokenStarted = true
                continue
            }

            if scalar.properties.isWhitespace {
                if tokenStarted {
                    tokens.append(String(current))
                    current = String.UnicodeScalarView()
                    tokenStarted = false
                }
                continue
            }

            current.append(scalar)
            tokenStarted = true
        }

        if escapeNext {
            current.append("\\")
            tokenStarted = true
        }

        if tokenStarted {
            tokens.append(String(current))
        }

        return tokens
    }
}
