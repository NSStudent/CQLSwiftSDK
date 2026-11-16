/// A location in CQL source text (1-based line and column).
public struct SourceLocation: Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "\(line):\(column)" }
}

/// The kind of a lexical token.
///
/// Unicode symbols are normalised to the same kind as their ASCII equivalent
/// (for example `→` and `->` both produce ``attackArrow``; `⊢` produces the
/// keyword identifier `path`).
public enum TokenKind: Hashable, Sendable {
    case integer(Int)
    case string(String)
    /// A word: either a keyword (`check`, `find`…) or a variable name.
    case identifier(String)
    case pieceDesignator(PieceDesignator)
    /// `\n`, `\t`, `\"`, `\r`, `\\` outside quoted strings: a string literal.
    case escapedString(String)
    /// `\i`: i'th regex capture group.
    case captureGroup(Int)
    /// `\-i`: index of the i'th regex capture group.
    case captureGroupIndex(Int)

    case leftParen, rightParen, leftBrace, rightBrace, leftBracket, rightBracket
    case comma, colon, hash, question
    case plus, minus, star, slash, percent
    case assign            // =
    case assignIfNonEmpty  // =?
    case equal             // ==
    case notEqual          // != ≠
    case less, lessEqual, greater, greaterEqual   // < <= ≤ > >= ≥
    case plusAssign, minusAssign, starAssign, slashAssign, percentAssign
    case tilde             // ~
    case tildeTilde        // ~~
    case union             // | ∪
    case intersection      // & ∩
    case dot               // .
    case dash              // -- ――
    case capture           // [x] ×
    case lineForward       // -->
    case lineBackward      // <--
    case attackArrow       // -> →
    case attackedArrow     // <- ←
    case element           // [element] ∊
    case forall            // [forall] ∀
    case precedes          // [<] ≺
    case succeeds          // [>] ≻
    case precedesOrEqual   // [<=] ≼
    case succeedsOrEqual   // [>=] ≽
    case annotation        // ///
    case endOfFile
}

/// A lexical token with its source location.
public struct Token: Hashable, Sendable, CustomStringConvertible {
    public var kind: TokenKind
    /// The exact source text of the token.
    public var text: String
    public var location: SourceLocation
    /// Whether whitespace or a comment separates this token from the previous one.
    public var precededBySpace: Bool
    /// Whether a blank line separates this token from the previous one (ends `⊢` filters).
    public var precededByBlankLine: Bool

    public init(kind: TokenKind, text: String, location: SourceLocation, precededBySpace: Bool,
                precededByBlankLine: Bool = false) {
        self.kind = kind
        self.text = text
        self.location = location
        self.precededBySpace = precededBySpace
        self.precededByBlankLine = precededByBlankLine
    }

    public var description: String { "\(text)@\(location)" }

    /// The identifier text, if this token is an identifier.
    public var identifier: String? {
        if case .identifier(let name) = kind { return name }
        return nil
    }
}
