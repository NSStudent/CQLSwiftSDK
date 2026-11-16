/// Precedence levels (higher binds tighter). See Docs/Reference/01-language-core.md §3.2.
enum Precedence {
    static let lowest = 0
    static let or = 30
    static let and = 40
    static let notArgument = 60       // `not` absorbs `in` and above
    static let `in` = 60
    static let relational = 70
    static let regex = 85
    static let numericArgument = 100  // "just lower than +"
    static let additive = 100
    static let caseArgument = 120
    static let unaryMinusArgument = 130
    static let multiplicative = 130
    static let setArgument = 150      // "just lower than |"
    static let dash = 145
    static let union = 150
    static let intersection = 160
    static let complementArgument = 180
    static let arrow = 180
    static let pinArgument = 200
    static let directionArgument = 210
    static let `subscript` = 210
    static let colon = 220
}

/// Recursive-descent / precedence-climbing parser for CQL 6.2.
public struct Parser {
    var tokens: [Token]
    var position = 0

    /// Static types of variables seen so far.
    var variableTypes: [String: ValueType] = [:]
    var dictionaries: Set<String> = []
    var functions: [String: FunctionDefinition] = [:]
    /// > 0 while parsing inside `[ … ]` where `:` is a slice separator.
    var colonDisabled = 0
    /// True while parsing `str`/`comment`/`message` argument lists (implicit
    /// search literals become separate arguments).
    var inOutputArguments = false
    var functionsBeingDefined: Set<String> = []
    var hiddenVariableCounter = 0
    /// True while parsing ⊢ constituents outside braces: `+ * ? {m,n}` are
    /// repetition signals and ―― filters take no target list.
    var pathTopLevel = false

    public init(tokens: [Token]) {
        self.tokens = tokens
    }

    /// Parses a complete CQL program (header and body).
    public static func parse(_ source: String) throws(CQLError) -> CQLProgram {
        var parser = Parser(tokens: try Lexer.tokenize(source))
        return try parser.parseProgram()
    }

    mutating func parseProgram() throws(CQLError) -> CQLProgram {
        let header = try parseHeader()
        let body = try parseSequence(until: .endOfFile)
        guard current.kind == .endOfFile else {
            throw error("unexpected '\(current.text)'")
        }
        return CQLProgram(header: header, body: .compound(body), functions: functions)
    }

    // MARK: - Cursor

    var current: Token { tokens[position] }

    func peek(_ offset: Int = 1) -> Token {
        tokens[min(position + offset, tokens.count - 1)]
    }

    mutating func advance() {
        if position < tokens.count - 1 { position += 1 }
    }

    mutating func expect(_ kind: TokenKind, _ context: String) throws(CQLError) {
        guard current.kind == kind else {
            throw CQLError(.parsing, "expected \(Self.describe(kind)) \(context), found '\(current.text)'", at: current.location)
        }
        advance()
    }

    /// Consumes the current token if it has the given kind.
    mutating func accept(_ kind: TokenKind) -> Bool {
        guard current.kind == kind else { return false }
        advance()
        return true
    }

    /// Consumes the current token if it is the given keyword.
    mutating func accept(keyword: String) -> Bool {
        guard current.identifier == keyword else { return false }
        advance()
        return true
    }

    func error(_ message: String, at token: Token? = nil) -> CQLError {
        CQLError(.parsing, message, at: (token ?? current).location)
    }

    static func describe(_ kind: TokenKind) -> String {
        switch kind {
        case .leftParen: "'('"
        case .rightParen: "')'"
        case .leftBrace: "'{'"
        case .rightBrace: "'}'"
        case .leftBracket: "'['"
        case .rightBracket: "']'"
        case .assign: "'='"
        case .colon: "':'"
        case .element: "'∊'"
        case .endOfFile: "end of file"
        default: "\(kind)"
        }
    }

    // MARK: - Sequences

    /// Parses juxtaposed filters until `terminator` (not consumed).
    mutating func parseSequence(until terminator: TokenKind) throws(CQLError) -> [Filter] {
        var filters: [Filter] = []
        while current.kind != terminator, current.kind != .endOfFile {
            if current.identifier == "function" {
                try parseFunctionDefinition()
                continue
            }
            filters.append(try parseExpression())
        }
        return filters
    }

    mutating func parseFunctionDefinition() throws(CQLError) {
        advance()
        guard let name = current.identifier else { throw error("expected a function name") }
        guard !Self.reservedWords.contains(name) else { throw error("'\(name)' is a CQL keyword") }
        advance()
        try expect(.leftParen, "after function name")
        var parameters: [String] = []
        while let parameter = current.identifier {
            parameters.append(parameter)
            advance()
        }
        try expect(.rightParen, "after function parameters")
        guard current.kind == .leftBrace else { throw error("expected '{' to start the function body") }
        let saved = variableTypes
        for parameter in parameters { variableTypes[parameter] = .unknown }
        // Register first so that misuse can be reported; recursion is rejected at call time.
        functions[name] = FunctionDefinition(name: name, parameters: parameters, body: .compound([]))
        functionsBeingDefined.insert(name)
        let body = try parsePrimary()
        functionsBeingDefined.remove(name)
        variableTypes = saved
        functions[name] = FunctionDefinition(name: name, parameters: parameters, body: body)
    }

    // MARK: - Expressions

    mutating func parseExpression(_ minimum: Int = Precedence.lowest, typeDirected: Bool = false) throws(CQLError) -> Filter {
        var left = try parsePrimary()
        return try parseInfix(left: &left, minimum: minimum, typeDirected: typeDirected)
    }

    mutating func parseInfix(left: inout Filter, minimum: Int, typeDirected: Bool) throws(CQLError) -> Filter {
        while true {
            let token = current
            switch token.kind {
            case .identifier("or"):
                guard Precedence.or >= minimum else { return left }
                advance()
                left = .binary(.or, left, try parseExpression(Precedence.or + 1))
            case .identifier("and"):
                guard Precedence.and >= minimum else { return left }
                advance()
                left = .binary(.and, left, try parseExpression(Precedence.and + 1))
            case .identifier("in"):
                guard Precedence.in >= minimum else { return left }
                advance()
                left = .binary(.in, left, try parseExpression(Precedence.in + 1))
            case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual,
                 .precedes, .succeeds, .precedesOrEqual, .succeedsOrEqual:
                guard Precedence.relational >= minimum else { return left }
                // A logical filter has no value to compare: the comparison
                // applies to the enclosing filter (`sort find all check>20`).
                if typeOf(left) == .logical { return left }
                advance()
                // Right-associative.
                let right = try parseExpression(Precedence.relational)
                left = .binary(Self.relationalOperator(token.kind), left, right)
            case .tildeTilde:
                guard Precedence.regex >= minimum else { return left }
                advance()
                left = .binary(.regexMatch, left, try parseRegexPattern())
            case .plus, .minus:
                guard Precedence.additive >= minimum, !(pathTopLevel && token.kind == .plus) else { return left }
                let op: BinaryOperator = token.kind == .plus ? .add : .subtract
                guard let combined = try parseArithmetic(op, left: left, level: Precedence.additive, typeDirected: typeDirected) else {
                    return left
                }
                left = combined
            case .star, .slash, .percent:
                guard Precedence.multiplicative >= minimum, !(pathTopLevel && token.kind == .star) else { return left }
                let op: BinaryOperator = token.kind == .star ? .multiply : token.kind == .slash ? .divide : .modulo
                guard let combined = try parseArithmetic(op, left: left, level: Precedence.multiplicative, typeDirected: typeDirected) else {
                    return left
                }
                left = combined
            case .dash, .capture:
                guard !token.precededBySpace, Precedence.dash >= minimum else { return left }
                left = try parseDash(left: left)
            case .union:
                guard Precedence.union >= minimum else { return left }
                advance()
                left = .binary(.union, left, try parseExpression(Precedence.union + 1))
            case .intersection:
                guard Precedence.intersection >= minimum else { return left }
                advance()
                left = .binary(.intersection, left, try parseExpression(Precedence.intersection + 1))
            case .attackArrow, .attackedArrow:
                guard Precedence.arrow >= minimum else { return left }
                var operands = [left]
                while current.kind == token.kind {
                    advance()
                    operands.append(try parseExpression(Precedence.arrow + 1))
                }
                if current.kind == .attackArrow || current.kind == .attackedArrow {
                    throw error("mixed → and ← chains are not allowed; use parentheses")
                }
                left = .attackChain(operands, reversed: token.kind == .attackedArrow)
            case .identifier("attacks"), .identifier("attackedby"):
                guard Precedence.arrow >= minimum else { return left }
                advance()
                let right = try parseExpression(Precedence.arrow + 1)
                left = .attackChain([left, right], reversed: token.identifier == "attackedby")
            case .leftBracket:
                guard Precedence.subscript >= minimum else { return left }
                left = try parseSubscript(of: left)
            case .colon:
                guard colonDisabled == 0, Precedence.colon >= minimum else { return left }
                let leftType = typeOf(left)
                guard leftType == .position || leftType == .unknown else { return left }
                advance()
                left = .at(left, try parseExpression(Precedence.colon))
            default:
                return left
            }
        }
    }

    /// Parses the right operand of an arithmetic operator. With
    /// `typeDirected`, returns `nil` (consuming nothing) when the combination
    /// would be ill-typed, so the operator applies to the enclosing prefix
    /// filter's result instead (`#♖ + #♛`, `ascii 65 + "C"`).
    mutating func parseArithmetic(_ op: BinaryOperator, left: Filter, level: Int, typeDirected: Bool) throws(CQLError) -> Filter? {
        let saved = position
        advance()
        let right = try parseExpression(level + 1)
        if typeDirected {
            let lhs = typeOf(left), rhs = typeOf(right)
            if !Self.arithmeticIsValid(op, lhs, rhs) {
                position = saved
                return nil
            }
        }
        return .binary(op, left, right)
    }

    static func arithmeticIsValid(_ op: BinaryOperator, _ lhs: ValueType, _ rhs: ValueType) -> Bool {
        if lhs == .unknown || rhs == .unknown { return true }
        if op == .add, lhs == .string, rhs == .string { return true }
        return lhs == .number && rhs == .number
    }

    static func relationalOperator(_ kind: TokenKind) -> BinaryOperator {
        switch kind {
        case .equal: .equal
        case .notEqual: .notEqual
        case .less: .less
        case .lessEqual: .lessEqual
        case .greater: .greater
        case .greaterEqual: .greaterEqual
        case .precedes: .precedes
        case .succeeds: .succeeds
        case .precedesOrEqual: .precedesOrEqual
        default: .succeedsOrEqual
        }
    }

    mutating func parseRegexPattern() throws(CQLError) -> Filter {
        switch current.kind {
        case .string(let text), .escapedString(let text):
            advance()
            return .string(text)
        default:
            throw error("the right side of ~~ must be a string literal")
        }
    }

    /// `x[i]`, `x[m:n]`, `D[key]`
    mutating func parseSubscript(of target: Filter) throws(CQLError) -> Filter {
        advance()  // [
        colonDisabled += 1
        let savedTopLevel = pathTopLevel
        pathTopLevel = false
        defer {
            colonDisabled -= 1
            pathTopLevel = savedTopLevel
        }
        var start: Filter?
        if current.kind != .colon { start = try parseExpression() }
        if accept(.colon) {
            var end: Filter?
            if current.kind != .rightBracket { end = try parseExpression() }
            try expect(.rightBracket, "to close the slice")
            return .subscript(target, start, end, isSlice: true)
        }
        try expect(.rightBracket, "to close the subscript")
        return .subscript(target, start, nil, isSlice: false)
    }

    // MARK: - Dash

    /// Parses the rest of a `――`/`×` filter whose operator is the current token.
    mutating func parseDash(left: Filter?) throws(CQLError) -> Filter {
        let isCapture = current.kind == .capture
        advance()
        var dash = DashFilter(left: left, isCapture: isCapture)
        if !current.precededBySpace, canStartOperand(current), current.kind != .leftParen, current.kind != .assign,
           !(pathTopLevel && braceRepetition() != nil) {
            dash.right = try parseExpression(Precedence.union)
        }
        if !current.precededBySpace, current.kind == .assign {
            advance()
            if case .identifier(let name) = current.kind, !Self.reservedWords.contains(name) {
                advance()
                dash.promotionFilter = .variable(name)
            } else {
                dash.promotion = try parsePromotionTypes()
            }
        }
        if !current.precededBySpace, current.kind == .leftParen, !pathTopLevel {
            advance()
            dash.targets = try parseSequence(until: .rightParen)
            try expect(.rightParen, "to close the move target list")
        }
        return .dash(dash, source: .game)
    }

    mutating func parsePromotionTypes() throws(CQLError) -> PieceTypeSet {
        switch current.kind {
        case .pieceDesignator(let designator) where designator.squares == .all:
            advance()
            return designator.pieceTypes
        case .string(let text):
            advance()
            var types = PieceTypeSet()
            for character in text {
                guard let simple = PieceTypeSet(character: character) else {
                    throw error("invalid promotion piece '\(character)'")
                }
                types.formUnion(simple)
            }
            return types
        default:
            throw error("expected a promotion piece type after '='")
        }
    }

    func canStartOperand(_ token: Token) -> Bool {
        switch token.kind {
        case .integer, .string, .escapedString, .pieceDesignator, .leftParen, .leftBrace, .tilde, .hash, .minus,
             .dot, .captureGroup, .captureGroupIndex, .dash, .capture, .forall, .leftBracket:
            return true
        case .identifier(let name):
            return !["and", "or", "in", "attacks", "attackedby", "else", "then"].contains(name)
        default:
            return false
        }
    }
}
