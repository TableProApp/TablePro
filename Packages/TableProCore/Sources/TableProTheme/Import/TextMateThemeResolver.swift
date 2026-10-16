import Foundation

// A port of microsoft/vscode-textmate src/theme.ts at 4e96221f20fb3edab61860bac174423952839255
// (parseTheme, resolveParsedThemeRules, ColorMap, ThemeTrieElement, Theme.match) and of the per-scope
// merge in grammar.ts AttributedScopeStack, the engine that colors a .sql file in VS Code. Only the
// foreground is carried: the TablePro format has no font style or token background. Strings compare
// by UTF-16 code unit, as JavaScript does.

internal struct TextMateRule: Equatable, Sendable {
    internal enum Scope: Equatable, Sendable {
        case unscoped
        case selector(String)
        case selectors([String])
    }

    internal var scope: Scope
    internal var foreground: String?
}

internal struct TextMateThemeResolver {
    // A real theme has at most a few hundred rules. Inserting is quadratic in rules that share a node,
    // so an untrusted file is capped well before that costs seconds.
    internal static let maximumRuleCount = 10_000

    // Far above what a theme writes. Each scope part is a trie node, so the part cap bounds the nodes
    // a rule adds; the length cap bounds the parent scopes a rule carries.
    internal static let maximumSelectorLength = 4_096
    internal static let maximumScopeParts = 32

    internal let defaultForeground: String
    private let colorMap: TextMateColorMap
    private let root: TextMateTrieElement

    internal init(rules: [TextMateRule]) throws {
        let parsed = try Self.parse(rules).sorted { lhs, rhs in
            let scopeOrder = TextMateText.compare(lhs.scope, rhs.scope)
            if scopeOrder != 0 { return scopeOrder < 0 }
            let parentOrder = TextMateText.compare(lhs.parentScopes, rhs.parentScopes)
            if parentOrder != 0 { return parentOrder < 0 }
            return lhs.index < rhs.index
        }

        var remaining = parsed[...]
        var defaultForeground = "#000000"
        while let first = remaining.first, first.scope.isEmpty {
            remaining = remaining.dropFirst()
            if let foreground = first.foreground {
                defaultForeground = foreground
            }
        }

        let colorMap = TextMateColorMap()
        self.defaultForeground = colorMap.color(for: colorMap.id(for: defaultForeground))

        let root = TextMateTrieElement(mainRule: TextMateTrieRule(scopeDepth: 0, parentScopes: nil, foreground: 0))
        for rule in remaining {
            root.insert(scope: rule.scope, parentScopes: rule.parentScopes, foreground: colorMap.id(for: rule.foreground))
        }
        self.colorMap = colorMap
        self.root = root
    }

    // `scopes` runs from the grammar's root scope to the token's own, the order a grammar pushes them.
    // Nil when no rule sets a foreground, so the token keeps the default.
    internal func foreground(forScopes scopes: [String]) -> String? {
        var foreground = 0
        for depth in scopes.indices {
            let parentPath = Array(scopes[..<depth].reversed())
            guard let rule = match(scopes[depth], parentPath: parentPath), rule.foreground != 0 else { continue }
            foreground = rule.foreground
        }
        return foreground == 0 ? nil : colorMap.color(for: foreground)
    }

    private func match(_ scopeName: String, parentPath: [String]) -> TextMateTrieRule? {
        root.match(scopeName).first { Self.scopePath(parentPath, matchesParentScopes: $0.parentScopes) }
    }

    // `path` is innermost first. `>` is the child combinator; `-` has no meaning here.
    private static func scopePath(_ path: [String], matchesParentScopes parentScopes: [String]) -> Bool {
        guard !parentScopes.isEmpty else { return true }

        var position = 0
        var index = 0
        while index < parentScopes.count {
            var pattern = parentScopes[index]
            var mustMatch = false
            if pattern == ">" {
                guard index < parentScopes.count - 1 else { return false }
                index += 1
                pattern = parentScopes[index]
                mustMatch = true
            }

            while position < path.count {
                if TextMateText.matchesScope(path[position], pattern: pattern) {
                    break
                }
                if mustMatch {
                    return false
                }
                position += 1
            }
            guard position < path.count else { return false }
            position += 1
            index += 1
        }
        return true
    }

    private struct ParsedRule {
        let scope: String
        let parentScopes: [String]?
        let index: Int
        let foreground: String?
    }

    private static func parse(_ rules: [TextMateRule]) throws -> [ParsedRule] {
        var result: [ParsedRule] = []
        for (index, rule) in rules.enumerated() {
            let selectors: [String]
            switch rule.scope {
            case let .selector(selector):
                selectors = TextMateText.trimmingCommas(selector).components(separatedBy: ",")
            case let .selectors(list):
                selectors = list
            case .unscoped:
                selectors = [""]
            }

            let foreground = rule.foreground.flatMap { VSCodeColorSyntax.normalized($0) == nil ? nil : $0 }

            for selector in selectors {
                let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.utf16.count <= maximumSelectorLength else {
                    throw ThemeLoadError.tokenScopeTooLong(limit: maximumSelectorLength)
                }
                let segments = trimmed.components(separatedBy: " ")
                guard segments.allSatisfy({ TextMateText.partCount($0) <= maximumScopeParts }) else {
                    throw ThemeLoadError.tokenScopeHasTooManyParts(limit: maximumScopeParts)
                }
                let parentScopes = segments.count > 1 ? Array(segments.dropLast().reversed()) : nil
                result.append(
                    ParsedRule(scope: segments.last ?? "", parentScopes: parentScopes, index: index, foreground: foreground)
                )
                guard result.count <= maximumRuleCount else {
                    throw ThemeLoadError.tooManyTokenRules(limit: maximumRuleCount)
                }
            }
        }
        return result
    }
}

private final class TextMateColorMap {
    private var colors: [String] = [""]
    private var ids: [String: Int] = [:]

    func id(for color: String?) -> Int {
        guard let color else { return 0 }
        let key = color.uppercased()
        if let existing = ids[key] {
            return existing
        }
        colors.append(key)
        ids[key] = colors.count - 1
        return colors.count - 1
    }

    func color(for id: Int) -> String {
        colors[id]
    }
}

// A value, where vscode-textmate has an object it clones: a child node starts as a copy of its
// parent's rules, and copy-on-write defers that copy until a rule lands on the child itself.
private struct TextMateTrieRule {
    var scopeDepth: Int
    let parentScopes: [String]
    var foreground: Int

    init(scopeDepth: Int, parentScopes: [String]?, foreground: Int) {
        self.scopeDepth = scopeDepth
        self.parentScopes = parentScopes ?? []
        self.foreground = foreground
    }

    mutating func acceptOverwrite(scopeDepth: Int, foreground: Int) {
        if self.scopeDepth <= scopeDepth {
            self.scopeDepth = scopeDepth
        }
        if foreground != 0 {
            self.foreground = foreground
        }
    }
}

// vscode-textmate walks the trie by recursion, one call per scope part. Here both walks are loops,
// so a file's scope sets no stack depth.
private final class TextMateTrieElement {
    private var mainRule: TextMateTrieRule
    private var rulesWithParentScopes: [TextMateTrieRule]
    private var children: [String: TextMateTrieElement] = [:]

    init(mainRule: TextMateTrieRule, rulesWithParentScopes: [TextMateTrieRule] = []) {
        self.mainRule = mainRule
        self.rulesWithParentScopes = rulesWithParentScopes
    }

    func match(_ scope: String) -> [TextMateTrieRule] {
        var node = self
        var remaining = Substring(scope)
        while !remaining.isEmpty {
            let (head, tail) = TextMateText.splitFirstSegment(remaining)
            guard let child = node.children[String(head)] else { break }
            node = child
            remaining = tail
        }
        return node.rulesBySpecificity()
    }

    func insert(scope: String, parentScopes: [String]?, foreground: Int) {
        var node = self
        var scopeDepth = 0
        var remaining = Substring(scope)
        while !remaining.isEmpty {
            let (head, tail) = TextMateText.splitFirstSegment(remaining)
            node = node.child(named: String(head))
            scopeDepth += 1
            remaining = tail
        }
        node.insertHere(scopeDepth: scopeDepth, parentScopes: parentScopes, foreground: foreground)
    }

    // Array.prototype.sort is stable, so equally specific rules keep their insertion order.
    private func rulesBySpecificity() -> [TextMateTrieRule] {
        (rulesWithParentScopes + [mainRule])
            .enumerated()
            .sorted { lhs, rhs in
                let order = Self.compareBySpecificity(lhs.element, rhs.element)
                return order != 0 ? order < 0 : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func child(named name: String) -> TextMateTrieElement {
        if let existing = children[name] {
            return existing
        }
        let child = TextMateTrieElement(mainRule: mainRule, rulesWithParentScopes: rulesWithParentScopes)
        children[name] = child
        return child
    }

    private func insertHere(scopeDepth: Int, parentScopes: [String]?, foreground: Int) {
        guard let parentScopes else {
            mainRule.acceptOverwrite(scopeDepth: scopeDepth, foreground: foreground)
            return
        }

        if let index = rulesWithParentScopes.firstIndex(where: { TextMateText.compare($0.parentScopes, parentScopes) == 0 }) {
            rulesWithParentScopes[index].acceptOverwrite(scopeDepth: scopeDepth, foreground: foreground)
            return
        }

        rulesWithParentScopes.append(
            TextMateTrieRule(
                scopeDepth: scopeDepth,
                parentScopes: parentScopes,
                foreground: foreground == 0 ? mainRule.foreground : foreground
            )
        )
    }

    // Deeper scope first, then the longer parent at each level from the innermost, then more parents.
    private static func compareBySpecificity(_ lhs: TextMateTrieRule, _ rhs: TextMateTrieRule) -> Int {
        if lhs.scopeDepth != rhs.scopeDepth {
            return rhs.scopeDepth - lhs.scopeDepth
        }

        var lhsIndex = 0
        var rhsIndex = 0
        while true {
            if lhsIndex < lhs.parentScopes.count, lhs.parentScopes[lhsIndex] == ">" {
                lhsIndex += 1
            }
            if rhsIndex < rhs.parentScopes.count, rhs.parentScopes[rhsIndex] == ">" {
                rhsIndex += 1
            }
            guard lhsIndex < lhs.parentScopes.count, rhsIndex < rhs.parentScopes.count else { break }

            let lengthDifference = rhs.parentScopes[rhsIndex].utf16.count - lhs.parentScopes[lhsIndex].utf16.count
            if lengthDifference != 0 {
                return lengthDifference
            }
            lhsIndex += 1
            rhsIndex += 1
        }
        return rhs.parentScopes.count - lhs.parentScopes.count
    }
}

private enum TextMateText {
    // utils.ts strcmp on UTF-16 code units.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        var left = lhs.utf16.makeIterator()
        var right = rhs.utf16.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (leftUnit?, rightUnit?) where leftUnit != rightUnit: return leftUnit < rightUnit ? -1 : 1
            default: continue
            }
        }
    }

    // utils.ts strArrCmp: nil first, then the shorter list, then element by element.
    static func compare(_ lhs: [String]?, _ rhs: [String]?) -> Int {
        switch (lhs, rhs) {
        case (nil, nil):
            return 0
        case (nil, _):
            return -1
        case (_, nil):
            return 1
        case let (left?, right?):
            guard left.count == right.count else { return left.count - right.count }
            for (leftItem, rightItem) in zip(left, right) {
                let order = compare(leftItem, rightItem)
                if order != 0 {
                    return order
                }
            }
            return 0
        }
    }

    // `keyword` matches `keyword` and `keyword.control`, never `keywords`.
    static func matchesScope(_ scopeName: String, pattern: String) -> Bool {
        guard scopeName.utf16.starts(with: pattern.utf16) else { return false }
        let remainder = scopeName.utf16.dropFirst(pattern.utf16.count)
        return remainder.isEmpty || remainder.first == UInt16(UInt8(ascii: "."))
    }

    // indexOf('.') finds a dot a combining mark follows, which a Character search would not.
    static func splitFirstSegment(_ scope: Substring) -> (head: Substring, tail: Substring) {
        guard let dot = scope.utf8.firstIndex(of: dotByte) else { return (scope, scope[scope.endIndex...]) }
        return (scope[..<dot], scope[scope.utf8.index(after: dot)...])
    }

    static func partCount(_ scope: String) -> Int {
        scope.utf8.lazy.filter { $0 == dotByte }.count + 1
    }

    private static let dotByte = UInt8(ascii: ".")

    static func trimmingCommas(_ selector: String) -> String {
        var trimmed = Substring(selector)
        while trimmed.first == "," {
            trimmed = trimmed.dropFirst()
        }
        while trimmed.last == "," {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }
}
