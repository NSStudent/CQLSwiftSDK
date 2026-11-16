/// An error produced while reading or running CQL.
public struct CQLError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Phase: String, Sendable {
        case lexing, parsing, semantic, runtime, input
    }

    public var phase: Phase
    public var message: String
    public var location: SourceLocation?

    public init(_ phase: Phase, _ message: String, at location: SourceLocation? = nil) {
        self.phase = phase
        self.message = message
        self.location = location
    }

    public var description: String {
        if let location { return "\(phase) error at \(location): \(message)" }
        return "\(phase) error: \(message)"
    }
}

/// Converts CQL source text into tokens.
///
/// The lexer accepts both the ASCII and the Unicode spellings of every CQL
/// symbol and normalises them to a single ``TokenKind``.
public struct Lexer {
    private let chars: [Character]
    private var index = 0
    private var line = 1
    private var column = 1
    private var sawSpace = true
    /// A newline was seen and the current line has had no content yet.
    private var pendingNewline = false
    private var sawBlankLine = false
    private var lastKind: TokenKind?

    public init(_ source: String) {
        self.chars = Array(source)
    }

    /// Tokenises the whole input. The last token is always ``TokenKind/endOfFile``.
    public static func tokenize(_ source: String) throws(CQLError) -> [Token] {
        var lexer = Lexer(source)
        var tokens: [Token] = []
        while true {
            let token = try lexer.nextToken()
            tokens.append(token)
            if token.kind == .endOfFile { return tokens }
        }
    }

    // MARK: - Character helpers

    private func peek(_ offset: Int = 0) -> Character? {
        let position = index + offset
        return position < chars.count ? chars[position] : nil
    }

    private func starts(with text: String, at offset: Int = 0) -> Bool {
        var position = index + offset
        for character in text {
            guard position < chars.count, chars[position] == character else { return false }
            position += 1
        }
        return true
    }

    private mutating func advance(_ count: Int = 1) {
        for _ in 0..<count where index < chars.count {
            if chars[index] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }
    }

    static func isIdentifierStart(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character == "_" || character == "$")
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "$")
    }

    private static func isFile(_ character: Character?) -> Bool {
        guard let character, let ascii = character.asciiValue else { return false }
        return (97...104).contains(ascii)
    }

    private static func isRank(_ character: Character?) -> Bool {
        guard let character, let ascii = character.asciiValue else { return false }
        return (49...56).contains(ascii)
    }

    // MARK: - Whitespace and comments

    private mutating func skipTrivia() throws(CQLError) {
        while let character = peek() {
            if character.isWhitespace {
                sawSpace = true
                if character.isNewline {
                    if pendingNewline { sawBlankLine = true }
                    pendingNewline = true
                }
                advance()
            } else if starts(with: "////") || (starts(with: "//") && !starts(with: "///")) {
                sawSpace = true
                pendingNewline = false
                while let next = peek(), next != "\n" { advance() }
            } else if starts(with: "/*") {
                sawSpace = true
                pendingNewline = false
                let start = SourceLocation(line: line, column: column)
                advance(2)
                while !starts(with: "*/") {
                    guard peek() != nil else { throw CQLError(.lexing, "unterminated /* comment", at: start) }
                    advance()
                }
                advance(2)
            } else {
                return
            }
        }
    }

    // MARK: - Tokens

    public mutating func nextToken() throws(CQLError) -> Token {
        try skipTrivia()
        let location = SourceLocation(line: line, column: column)
        let start = index
        let space = sawSpace
        let blankLine = sawBlankLine
        sawSpace = false
        sawBlankLine = false
        pendingNewline = false

        func make(_ kind: TokenKind) -> Token {
            lastKind = kind
            return Token(kind: kind, text: String(chars[start..<index]), location: location, precededBySpace: space,
                         precededByBlankLine: blankLine)
        }

        guard let character = peek() else {
            return make(.endOfFile)
        }

        // Quoted strings (no escape sequences inside quotes).
        if character == "\"" {
            advance()
            var value = ""
            while let next = peek(), next != "\"" {
                value.append(next)
                advance()
            }
            guard peek() == "\"" else { throw CQLError(.lexing, "unterminated string literal", at: location) }
            advance()
            return make(.string(value))
        }

        // Predefined strings and capture groups: \n \t \" \r \\ \3 \-3
        if character == "\\" {
            advance()
            guard let next = peek() else { throw CQLError(.lexing, "dangling backslash", at: location) }
            switch next {
            case "n": advance(); return make(.escapedString("\n"))
            case "t": advance(); return make(.escapedString("\t"))
            case "r": advance(); return make(.escapedString("\r"))
            case "\"": advance(); return make(.escapedString("\""))
            case "\\": advance(); return make(.escapedString("\\"))
            case "-":
                advance()
                let digits = readDigits()
                guard let value = Int(digits) else { throw CQLError(.lexing, "expected digits after \\-", at: location) }
                return make(.captureGroupIndex(value))
            default:
                let digits = readDigits()
                guard let value = Int(digits) else { throw CQLError(.lexing, "unknown escape \\\(next)", at: location) }
                return make(.captureGroup(value))
            }
        }

        if character.isASCII, character.isNumber {
            let digits = readDigits()
            guard let value = Int(digits) else { throw CQLError(.lexing, "integer too large: \(digits)", at: location) }
            return make(.integer(value))
        }

        // Castling keywords contain hyphens.
        for keyword in ["o-o-o", "O-O-O", "o-o", "O-O"] where starts(with: keyword) {
            let after = peek(keyword.count)
            if after == nil || !Self.isIdentifierCharacter(after!) {
                advance(keyword.count)
                return make(.identifier(keyword.lowercased()))
            }
        }

        // `[` in subscript position: x[1], D["key"], f(x)[0]
        if character == "[", !space, let lastKind, Self.endsOperand(lastKind) {
            advance()
            return make(.leftBracket)
        }

        // Bracketed keyword symbols.
        let bracketSymbols: [(String, TokenKind)] = [
            ("[x]", .capture), ("[element]", .element), ("[forall]", .forall),
            ("[<=]", .precedesOrEqual), ("[>=]", .succeedsOrEqual), ("[<]", .precedes), ("[>]", .succeeds),
        ]
        if character == "[" {
            for (text, kind) in bracketSymbols where starts(with: text) {
                advance(text.count)
                return make(kind)
            }
        }

        // Piece designators.
        if let (designator, length) = scanPieceDesignator() {
            advance(length)
            return make(.pieceDesignator(designator))
        }

        if Self.isIdentifierStart(character) {
            var name = ""
            while let next = peek(), Self.isIdentifierCharacter(next) {
                name.append(next)
                advance()
            }
            return make(.identifier(name))
        }

        // Unicode keyword symbols.
        let unicodeKeywords: [Character: String] = [
            "⊢": "path", "◎": "focus", "✵": "flip", "⬓": "flipcolor", "∙": "currentposition",
        ]
        if let keyword = unicodeKeywords[character] {
            advance()
            return make(.identifier(keyword))
        }

        // Operators: longest match first.
        let operators: [(String, TokenKind)] = [
            ("――", .dash), ("―", .dash),
            ("///", .annotation),
            ("-->", .lineForward), ("<--", .lineBackward),
            ("--", .dash), ("->", .attackArrow), ("<-", .attackedArrow),
            ("==", .equal), ("=?", .assignIfNonEmpty), ("!=", .notEqual),
            ("<=", .lessEqual), (">=", .greaterEqual),
            ("+=", .plusAssign), ("-=", .minusAssign), ("*=", .starAssign), ("/=", .slashAssign), ("%=", .percentAssign),
            ("~~", .tildeTilde),
            ("=", .assign), ("<", .less), (">", .greater),
            ("+", .plus), ("-", .minus), ("*", .star), ("/", .slash), ("%", .percent),
            ("~", .tilde), ("|", .union), ("&", .intersection), ("#", .hash),
            (":", .colon), (",", .comma), ("?", .question), (".", .dot),
            ("(", .leftParen), (")", .rightParen), ("{", .leftBrace), ("}", .rightBrace),
            ("[", .leftBracket), ("]", .rightBracket),
            ("×", .capture), ("→", .attackArrow), ("←", .attackedArrow),
            ("≤", .lessEqual), ("≥", .greaterEqual), ("≠", .notEqual),
            ("∊", .element), ("∈", .element), ("∪", .union), ("∩", .intersection), ("∀", .forall),
            ("≺", .precedes), ("≻", .succeeds), ("≼", .precedesOrEqual), ("≽", .succeedsOrEqual),
        ]
        for (text, kind) in operators where starts(with: text) {
            advance(text.count)
            return make(kind)
        }

        throw CQLError(.lexing, "unexpected character '\(character)'", at: location)
    }

    private mutating func readDigits() -> String {
        var digits = ""
        while let next = peek(), next.isASCII, next.isNumber {
            digits.append(next)
            advance()
        }
        return digits
    }

    /// Whether a token of this kind can be followed by a subscript `[`.
    private static func endsOperand(_ kind: TokenKind) -> Bool {
        switch kind {
        case .identifier, .string, .escapedString, .rightParen, .rightBracket, .rightBrace, .captureGroup:
            true
        default:
            false
        }
    }

    // MARK: - Piece designators

    /// Tries to read a piece designator at the current position, returning the
    /// designator and its length in characters.
    private func scanPieceDesignator() -> (PieceDesignator, Int)? {
        if peek() == "▦" { return (PieceDesignator(), 1) }

        var candidates: [(PieceDesignator, Int, Bool)] = []  // (designator, length, needsBoundary)

        // Piece-type part followed by an optional square part.
        if let (types, typeLength, isUnicode) = scanPieceTypes(at: 0) {
            if let (squares, squareLength) = scanSquares(at: typeLength) {
                candidates.append((PieceDesignator(pieceTypes: types, squares: squares), typeLength + squareLength, true))
            }
            candidates.append((PieceDesignator(pieceTypes: types), typeLength, !isUnicode))
        }
        // Square part alone.
        if let (squares, squareLength) = scanSquares(at: 0) {
            candidates.append((PieceDesignator(squares: squares), squareLength, true))
        }

        for (designator, length, needsBoundary) in candidates.sorted(by: { $0.1 > $1.1 }) {
            if needsBoundary, let after = peek(length), Self.isIdentifierCharacter(after) { continue }
            return (designator, length)
        }
        return nil
    }

    private func scanPieceTypes(at offset: Int) -> (PieceTypeSet, Int, Bool)? {
        guard let first = peek(offset) else { return nil }
        if first == "[" {
            var types = PieceTypeSet()
            var length = 1
            while let next = peek(offset + length), next != "]" {
                guard let simple = PieceTypeSet(character: next) else { return nil }
                types.formUnion(simple)
                length += 1
            }
            guard length > 1, peek(offset + length) == "]" else { return nil }
            return (types, length + 1, false)
        }
        if PieceTypeSet.isUnicodePieceCharacter(first) {
            var types = PieceTypeSet()
            var length = 0
            while let next = peek(offset + length), PieceTypeSet.isUnicodePieceCharacter(next) {
                types.formUnion(PieceTypeSet(character: next)!)
                length += 1
            }
            return (types, length, true)
        }
        if "KQRBNPkqrbnpAa_".contains(first), let types = PieceTypeSet(character: first) {
            return (types, 1, false)
        }
        return nil
    }

    private func scanSquares(at offset: Int) -> (SquareSet, Int)? {
        if peek(offset) == "[" {
            var squares = SquareSet()
            var length = 1
            while true {
                guard let (simple, simpleLength) = scanSimpleSquares(at: offset + length) else { return nil }
                squares |= simple
                length += simpleLength
                if peek(offset + length) == "," {
                    length += 1
                    continue
                }
                guard peek(offset + length) == "]" else { return nil }
                return (squares, length + 1)
            }
        }
        return scanSimpleSquares(at: offset)
    }

    private func scanSimpleSquares(at offset: Int) -> (SquareSet, Int)? {
        var length = 0
        func value(_ character: Character?, base: UInt8) -> Int { Int(character!.asciiValue! - base) }

        guard Self.isFile(peek(offset)) else { return nil }
        let fileStart = value(peek(offset), base: 97)
        var fileEnd = fileStart
        length = 1
        if peek(offset + 1) == "-", Self.isFile(peek(offset + 2)) {
            fileEnd = value(peek(offset + 2), base: 97)
            length = 3
        }
        guard Self.isRank(peek(offset + length)) else { return nil }
        let rankStart = value(peek(offset + length), base: 49)
        var rankEnd = rankStart
        length += 1
        if peek(offset + length) == "-", Self.isRank(peek(offset + length + 1)) {
            rankEnd = value(peek(offset + length + 1), base: 49)
            length += 2
        }
        guard fileStart <= fileEnd, rankStart <= rankEnd else { return nil }
        return (SquareSet.rectangle(files: fileStart...fileEnd, ranks: rankStart...rankEnd), length)
    }
}
