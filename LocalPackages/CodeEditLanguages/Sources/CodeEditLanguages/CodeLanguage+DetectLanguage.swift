//
//  CodeLanguage+DetectLanguage.swift
//  CodeEditLanguages
//
//  Created by Khan Winter on 6/17/23.
//

import Foundation
import RegexBuilder

public extension CodeLanguage {

    /// Gets the corresponding language for the given file URL
    ///
    /// Uses the `pathExtension` URL component to detect the language
    /// - Returns: A language structure
    /// - Parameters:
    ///   - url: The URL to get the language for.
    ///   - prefixBuffer: The first few lines of the document.
    ///   - suffixBuffer: The last few lines of the document.
    static func detectLanguageFrom(url: URL, prefixBuffer: String? = nil, suffixBuffer: String? = nil) -> CodeLanguage {
        if let urlLanguage = detectLanguageUsingURL(url: url) {
            return urlLanguage
        } else if let prefixBuffer,
                  let shebangLanguage = detectLanguageUsingShebang(contents: prefixBuffer.lowercased()) {
            return shebangLanguage
        } else if let prefixBuffer,
                  let modelineLanguage = detecLanguageUsingModeline(
                    prefixBuffer: prefixBuffer.lowercased(),
                    suffixBuffer: suffixBuffer?.lowercased()
                  ) {
            return modelineLanguage
        } else {
            return .default
        }
    }

    /// Detects a file's language using the file url.
    /// - Parameter url: The URL of the file.
    /// - Returns: The detected code language, if any.
    private static func detectLanguageUsingURL(url: URL) -> CodeLanguage? {
        let fileExtension = url.pathExtension.lowercased()
        let fileName = url.pathComponents.last // should not be lowercase since it has to match e.g. `Dockerfile`
        // This is to handle special file types without an extension (e.g., Makefile, Dockerfile)
        let fileNameOrExtension = fileExtension.isEmpty ? (fileName != nil ? fileName! : "") : fileExtension
        if let lang = allLanguages.first(where: { lang in lang.extensions.contains(fileNameOrExtension)}) {
            return lang
        } else {
            return nil
        }
    }

    /// Detects code langauges from the shebang of a file.
    /// Eg: `#!/usr/bin/env/python2.6` will detect the `python` code language.
    /// Or, `#! /usr/bin/env perl` will detect the `perl` code language.
    /// - Parameter contents: The contents of the first few lines of the file.
    /// - Returns: The detected code language, if any.
    private static func detectLanguageUsingShebang(contents: String) -> CodeLanguage? {
        var contents = String(contents.split(separator: "\n").first ?? "")
        guard
            contents.starts(with: "#!"),
            contents.trimmingCharacters(in: .whitespacesAndNewlines) != "#!",
            let result = contents
                .split(separator: "/", omittingEmptySubsequences: true)
                .last?
                .firstMatch(of: Regex { OneOrMore(.word) })
        else {
            return nil
        }

        var script = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        if script == "env" {
            guard result.endIndex != contents.endIndex else { return nil }

            let argumentRegex = Regex {
                ZeroOrMore(.whitespace)
                ChoiceOf {
                    One("-")
                    One("--")
                }
                ZeroOrMore(.word)
                ZeroOrMore(.whitespace)
            }
            let parameterRegex = Regex {
                OneOrMore(.word)
                One("=")
                OneOrMore(.word)
            }

            contents.trimPrefix(Regex {
                OneOrMore("#!")
                ZeroOrMore(.whitespace)
                OneOrMore(.any, .reluctant)
                OneOrMore(.whitespace)
            })
            while !contents.isEmpty {
                if contents.prefixMatch(of: argumentRegex) != nil {
                    contents.trimPrefix(argumentRegex)
                } else if contents.prefixMatch(of: parameterRegex) != nil {
                    contents.trimPrefix(parameterRegex)
                } else {
                    break
                }
            }
            guard let newScript = contents.firstMatch(of: Regex { OneOrMore(.word) })?.output else {
                return nil
            }
            script = String(newScript)
        }

        return languageFromIdentifier(script)
    }

    /// Detects modelines in either the beginning or end of a file.
    ///
    /// Examples of valid modelines:
    /// ```
    /// # vim: set ft=js ts=4 sw=4 et:
    /// # vim: ts=4:sw=4:et:ft=js
    /// -*- mode: js; indent-tabs-mode: nil; tab-width: 4 -*-
    /// code: language=javascript insertSpaces=true tabSize=4
    /// ```
    /// All of the above would resolve to `javascript`
    ///
    /// - Parameters:
    ///   - prefixBuffer: The first few lines of a document.
    ///   - suffixBuffer: The last few lines of a document.
    /// - Returns: The detected code language, if any.
    private static func detecLanguageUsingModeline(prefixBuffer: String, suffixBuffer: String?) -> CodeLanguage? {
        func detectModeline(in string: String) -> CodeLanguage? {
            guard !string.isEmpty else { return nil }

            let emacsLineRegex = Regex {
                "-*-"
                Capture {
                    #/.*/#
                }
                "-*-"
            }

            let emacsLanguageRegex = Regex {
                "mode:"
                ZeroOrMore(.whitespace)
                Capture {
                    OneOrMore(.word)
                }
            }

            let vimLineRegex = Regex {
                ChoiceOf {
                    One("//")
                    One("/*")
                }
                OneOrMore(.whitespace)
                #/vim:.*/#
                Optionally(.newlineSequence)
            }

            let vimLanguageRegex = Regex {
                "ft="
                Capture {
                    OneOrMore(.word)
                }
            }

            if let emacsLine = string.firstMatch(of: emacsLineRegex)?.1,
               let emacsLanguage = emacsLine.firstMatch(of: emacsLanguageRegex)?.1 {
                return languageFromIdentifier(String(emacsLanguage))
            } else if let vimLine = string.firstMatch(of: vimLineRegex)?.0,
                      let vimLanguage = vimLine.firstMatch(of: vimLanguageRegex)?.1 {
                return languageFromIdentifier(String(vimLanguage))
            } else {
                return nil
            }
        }

        return detectModeline(in: prefixBuffer) ?? detectModeline(in: suffixBuffer ?? "")
    }

    /// Finds a language to match a parsed identifier.
    /// - Parameter identifier: The identifier to use.
    /// - Returns: The found code language, if any.
    private static func languageFromIdentifier(_ identifier: String) -> CodeLanguage? {
        return allLanguages.first {
            $0.tsName == identifier
            || $0.extensions.contains(identifier)
            || $0.additionalIdentifiers.contains(identifier)
        }
    }
}
