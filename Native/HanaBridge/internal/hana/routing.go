package hana

import (
	"strings"
	"unicode"
)

var rowCountingKeywords = map[string]struct{}{
	"INSERT":  {},
	"UPDATE":  {},
	"DELETE":  {},
	"UPSERT":  {},
	"REPLACE": {},
	"MERGE":   {},
}

func routesToExec(statement string) bool {
	_, counts := rowCountingKeywords[leadingKeyword(statement)]
	return counts
}

func leadingKeyword(statement string) string {
	rest := statement
	for {
		rest = strings.TrimLeftFunc(rest, isStatementPadding)
		switch {
		case strings.HasPrefix(rest, "--"):
			lineEnd := strings.IndexAny(rest, "\r\n")
			if lineEnd < 0 {
				return ""
			}
			rest = rest[lineEnd+1:]
		case strings.HasPrefix(rest, "/*"):
			commentEnd := strings.Index(rest[2:], "*/")
			if commentEnd < 0 {
				return ""
			}
			rest = rest[commentEnd+4:]
		default:
			return strings.ToUpper(identifierPrefix(rest))
		}
	}
}

func isStatementPadding(character rune) bool {
	return unicode.IsSpace(character) || character == '\uFEFF' || character == '(' || character == ';'
}

func identifierPrefix(text string) string {
	end := 0
	for end < len(text) && isIdentifierByte(text[end]) {
		end++
	}
	return text[:end]
}

func isIdentifierByte(character byte) bool {
	switch {
	case character >= 'a' && character <= 'z', character >= 'A' && character <= 'Z', character >= '0' && character <= '9':
		return true
	default:
		return character == '_' || character == '#' || character == '$'
	}
}
