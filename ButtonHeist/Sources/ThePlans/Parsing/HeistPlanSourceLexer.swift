import Foundation

struct HeistPlanSourceLexer {
    let source: String
    let sourceName: String

    private var index: String.Index
    private var offset: Int
    private var line: Int
    private var column: Int

    init(source: String, sourceName: String) {
        self.source = source
        self.sourceName = sourceName
        self.index = source.startIndex
        self.offset = 0
        self.line = 1
        self.column = 1
    }

    mutating func lex() throws -> [HeistPlanSourceToken] {
        var tokens: [HeistPlanSourceToken] = []
        while true {
            try skipTrivia()
            guard let character = current else {
                tokens.append(token(.eof, length: 0))
                return tokens
            }
            if character == "\"" {
                tokens.append(try lexString())
            } else if character.isPlanSourceIdentifierStart {
                tokens.append(lexIdentifier())
            } else if character.isNumber {
                tokens.append(lexNumber())
            } else if HeistPlanSourceTokenKind.symbolCharacters.contains(character) {
                tokens.append(token(.symbol(character), length: 1))
                advance()
            } else {
                throw error("unsupported plan source token '\(character)'")
            }
        }
    }

    private var current: Character? {
        index < source.endIndex ? source[index] : nil
    }

    private func peek() -> Character? {
        guard index < source.endIndex else { return nil }
        let next = source.index(after: index)
        return next < source.endIndex ? source[next] : nil
    }

    private mutating func skipTrivia() throws {
        while let character = current {
            if character == "/" && peek() == "/" {
                while let current, current != "\n" {
                    advance()
                }
                continue
            }
            if character == "/" && peek() == "*" {
                try skipBlockComment()
                continue
            }
            guard character.isWhitespace else { return }
            advance()
        }
    }

    private mutating func skipBlockComment() throws {
        advance()
        advance()
        var depth = 1
        while let character = current {
            if character == "/" && peek() == "*" {
                depth += 1
                advance()
                advance()
                continue
            }
            if character == "*" && peek() == "/" {
                depth -= 1
                advance()
                advance()
                if depth == 0 { return }
                continue
            }
            advance()
        }
        throw error("unterminated block comment")
    }

    private mutating func lexIdentifier() -> HeistPlanSourceToken {
        let start = sourceSpan()
        var text = ""
        while let character = current, character.isPlanSourceIdentifierPart {
            text.append(character)
            advance()
        }
        return HeistPlanSourceToken(kind: .identifier(text), sourceSpan: start)
    }

    private mutating func lexNumber() -> HeistPlanSourceToken {
        let start = sourceSpan()
        var text = ""
        while let character = current, character.isNumber {
            text.append(character)
            advance()
        }
        if current == ".", let next = peek(), next.isNumber {
            text.append(".")
            advance()
            while let character = current, character.isNumber {
                text.append(character)
                advance()
            }
        }
        return HeistPlanSourceToken(kind: .number(text), sourceSpan: start)
    }

    private mutating func lexString() throws -> HeistPlanSourceToken {
        let start = sourceSpan()
        advance()
        var text = ""
        while let character = current {
            if character == "\"" {
                advance()
                return HeistPlanSourceToken(kind: .string(text), sourceSpan: start)
            }
            if character == "\\" {
                advance()
                guard let escaped = current else {
                    throw error("unterminated string escape")
                }
                if escaped == "(" {
                    throw error("string interpolation is not supported in ButtonHeist source")
                }
                switch escaped {
                case "\"": text.append("\"")
                case "\\": text.append("\\")
                case "n": text.append("\n")
                case "r": text.append("\r")
                case "t": text.append("\t")
                case "0": text.append("\0")
                case "u":
                    text.append(try lexUnicodeEscape())
                    continue
                default:
                    throw error("unsupported string escape '\\\(escaped)'")
                }
                advance()
                continue
            }
            if character == "\n" {
                throw error("unterminated string literal")
            }
            text.append(character)
            advance()
        }
        throw error("unterminated string literal")
    }

    private mutating func advance() {
        guard index < source.endIndex else { return }
        let character = source[index]
        index = source.index(after: index)
        offset += 1
        if character == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
    }

    private mutating func lexUnicodeEscape() throws -> Character {
        advance()
        var digits = ""
        for _ in 0..<4 {
            guard let character = current,
                  Int(String(character), radix: 16) != nil else {
                throw error("unsupported unicode escape; expected four hexadecimal digits after \\u")
            }
            digits.append(character)
            advance()
        }
        guard let scalar = Int(digits, radix: 16),
              let unicodeScalar = UnicodeScalar(scalar) else {
            throw error("invalid unicode escape scalar")
        }
        return Character(unicodeScalar)
    }

    private func token(_ kind: HeistPlanSourceTokenKind, length: Int) -> HeistPlanSourceToken {
        HeistPlanSourceToken(kind: kind, sourceSpan: sourceSpan(length: length))
    }

    private func sourceSpan(length: Int = 1) -> HeistBuildSourceSpan {
        HeistBuildSourceSpan(sourceName: sourceName, offset: offset, line: line, column: column, length: length)
    }

    private func error(_ message: String) -> HeistPlanBuildError {
        HeistPlanBuildError.sourceCompilation(
            message: message,
            sourceSpan: sourceSpan()
        )
    }
}

struct HeistPlanSourceToken: Equatable {
    let kind: HeistPlanSourceTokenKind
    let sourceSpan: HeistBuildSourceSpan

    func isSymbol(_ symbol: Character) -> Bool {
        kind == .symbol(symbol)
    }
}

enum HeistPlanSourceTokenKind: Equatable, CustomStringConvertible {
    case identifier(String)
    case string(String)
    case number(String)
    case symbol(Character)
    case eof

    static let symbolCharacters: Set<Character> = ["(", ")", "{", "}", "[", "]", ",", ":", ".", ";", "=", "!", "<", ">", "-"]

    var description: String {
        switch self {
        case .identifier(let value):
            return "identifier '\(value)'"
        case .string:
            return "string literal"
        case .number:
            return "number"
        case .symbol(let symbol):
            return "'\(symbol)'"
        case .eof:
            return "end of source"
        }
    }
}

private extension Character {
    var isPlanSourceIdentifierStart: Bool {
        self == "_" || isLetter
    }

    var isPlanSourceIdentifierPart: Bool {
        isPlanSourceIdentifierStart || isNumber
    }
}
