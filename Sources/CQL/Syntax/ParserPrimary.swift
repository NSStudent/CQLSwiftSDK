extension Parser {
    /// Filters without arguments, with their static type.
    static let simpleKeywords: [String: ValueType] = [
        "check": .logical, "mate": .logical, "stalemate": .logical, "wtm": .logical, "btm": .logical,
        "true": .logical, "false": .logical, "mainline": .logical, "variation": .logical,
        "virtualmainline": .logical, "terminal": .logical, "initial": .logical, "enpassant": .logical,
        "nullmove": .logical, "primary": .logical, "secondary": .logical, "o-o": .logical, "o-o-o": .logical,
        "castle": .logical, "removecomment": .logical, "try": .logical,
        "white": .number, "black": .number, "sidetomove": .number, "ply": .number, "positionid": .number,
        "movenumber": .number, "depth": .number, "gamenumber": .number, "lastgamenumber": .number,
        "year": .number,
        "from": .set, "to": .set, "enpassantsquare": .set, "passedpawns": .set, "doubledpawns": .set,
        "isolatedpawns": .set, "connectedpawns": .set,
        "puremate": .set, "modelmate": .set, "idealmate": .set,
        "purestalemate": .set, "modelstalemate": .set, "idealstalemate": .set,
        "currentposition": .position, "initialposition": .position, "parent": .position,
        "currenttransform": .string,
        "pathstart": .position, "pathlastposition": .position, "pathcount": .number, "pathcountunfocused": .number,
    ]

    /// Prefix filters with one argument: (argument precedence, type-directed, result type).
    static let prefixFilters: [String: (Int, Bool, ValueType)] = [
        "abs": (Precedence.numericArgument, true, .number),
        "sqrt": (Precedence.numericArgument, true, .number),
        "ascii": (Precedence.numericArgument, true, .unknown),
        "int": (Precedence.numericArgument, true, .number),
        "lowercase": (Precedence.caseArgument, false, .string),
        "uppercase": (Precedence.caseArgument, false, .string),
        "rank": (Precedence.setArgument, false, .number),
        "file": (Precedence.setArgument, false, .number),
        "power": (Precedence.setArgument, false, .number),
        "type": (Precedence.setArgument, false, .number),
        "colortype": (Precedence.setArgument, false, .number),
        "typename": (Precedence.setArgument, false, .string),
        "piecename": (Precedence.setArgument, false, .string),
        "pieceid": (Precedence.setArgument, false, .number),
        "light": (Precedence.directionArgument, false, .set),
        "dark": (Precedence.directionArgument, false, .set),
        "readfile": (Precedence.numericArgument, true, .string),
    ]

    static let directionNames: Set<String> = [
        "up", "down", "left", "right", "northeast", "northwest", "southeast", "southwest",
        "vertical", "horizontal", "orthogonal", "diagonal", "anydirection",
    ]

    /// Filters that are part of CQL 6.2 but not implemented yet.
    static let unsupportedFilters: Set<String> = [
        "line", "move", "similarposition", "hhdb", "writefile",
        "piecepath",
    ]

    static var reservedWords: Set<String> {
        var words = Set(simpleKeywords.keys).union(prefixFilters.keys).union(directionNames).union(unsupportedFilters)
        words.formUnion([
            "and", "or", "not", "in", "if", "then", "else", "while", "loop", "square", "piece", "all", "find",
            "echo", "sort", "min", "max", "comment", "message", "str", "between", "ray", "xray", "pin",
            "dictionary", "local", "persistent", "unbind", "isbound", "isunbound", "assert", "function",
            "legal", "pseudolegal", "currentmove", "countmoves", "child", "position", "lca", "distance",
            "ancestor", "descendant", "player", "event", "site", "date", "eventdate", "eco", "tag", "elo",
            "result", "fen", "originalcomment", "hascomment", "settag", "indexof", "makesquare", "notransform",
            "count", "quiet", "attacks", "attackedby", "cql", "path", "focus", "atomic", "consecutivemoves",
        ])
        words.formUnion(TransformKind.allCases.map(\.rawValue))
        return words
    }

    // MARK: - Primary

    mutating func parsePrimary() throws(CQLError) -> Filter {
        let token = current
        switch token.kind {
        case .integer(let value):
            advance()
            return .number(value)
        case .string(let text), .escapedString(let text):
            advance()
            return .string(text)
        case .captureGroup(let index):
            advance()
            return .captureGroup(index)
        case .captureGroupIndex(let index):
            advance()
            return .captureGroupIndex(index)
        case .dot:
            advance()
            return .pieceDesignator(PieceDesignator())
        case .pieceDesignator(let designator):
            advance()
            if designator == PieceDesignator(pieceTypes: .anyPiece), !current.precededBySpace,
               let name = current.identifier, !Self.reservedWords.contains(name) {
                return try parsePieceVariableForm(name)
            }
            return .pieceDesignator(designator)
        case .leftBracket:
            if peek().kind == .rightBracket {
                advance()
                advance()
                return .pieceDesignator(PieceDesignator(squares: .empty))
            }
            throw error("unexpected '['")
        case .leftParen:
            advance()
            let saved = (colonDisabled, pathTopLevel)
            colonDisabled = 0
            pathTopLevel = false
            let inner = try parseExpression()
            (colonDisabled, pathTopLevel) = saved
            guard current.kind == .rightParen else {
                throw error("a parenthesized expression must contain exactly one filter; found '\(current.text)'")
            }
            advance()
            return inner
        case .leftBrace:
            advance()
            let saved = (colonDisabled, pathTopLevel)
            colonDisabled = 0
            pathTopLevel = false
            let filters = try parseSequence(until: .rightBrace)
            (colonDisabled, pathTopLevel) = saved
            try expect(.rightBrace, "to close the compound filter")
            return .compound(filters)
        case .minus:
            advance()
            let operand = try parseExpression(Precedence.unaryMinusArgument)
            if case .number(let value) = operand { return .number(-value) }
            return .negate(operand)
        case .tilde:
            advance()
            return .complement(try parseExpression(Precedence.complementArgument))
        case .hash:
            advance()
            return .cardinality(try parseExpression(Precedence.numericArgument, typeDirected: true))
        case .dash, .capture:
            return try parseDash(left: nil)
        case .annotation:
            return try parseAnnotation()
        case .forall:
            advance()
            return try parseForall()
        case .identifier(let name):
            return try parseIdentifier(name)
        default:
            throw error("unexpected '\(token.text)'")
        }
    }

    /// `◭x = S`, `◭x ∊ S body`
    mutating func parsePieceVariableForm(_ name: String) throws(CQLError) -> Filter {
        advance()
        if accept(.assign) {
            variableTypes[name] = .piece
            return .pieceAssign(name, try parseExpression(Precedence.setArgument))
        }
        guard accept(.element) else { throw error("expected '=' or '∊' after ◭\(name)") }
        return try parseIterationBody(isPiece: true, all: false, variable: name)
    }

    /// After `∀`: `x∊S body` or `◭x∊S body`.
    mutating func parseForall() throws(CQLError) -> Filter {
        var isPiece = false
        if case .pieceDesignator(let designator) = current.kind, designator == PieceDesignator(pieceTypes: .anyPiece) {
            isPiece = true
            advance()
        }
        guard let name = current.identifier else { throw error("expected a variable after ∀") }
        advance()
        try expect(.element, "after ∀\(name)")
        return try parseIterationBody(isPiece: isPiece, all: true, variable: name)
    }

    mutating func parseIterationBody(isPiece: Bool, all: Bool, variable: String) throws(CQLError) -> Filter {
        let domain = try parseExpression(Precedence.setArgument)
        let saved = variableTypes[variable]
        variableTypes[variable] = isPiece ? .piece : .set
        let body = try parseExpression()
        variableTypes[variable] = saved
        return .iterate(isPiece: isPiece, all: all, variable: variable, domain: domain, body: body)
    }

    /// `/// args…` up to the end of the line.
    mutating func parseAnnotation() throws(CQLError) -> Filter {
        let line = current.location.line
        advance()
        let saved = inOutputArguments
        inOutputArguments = true
        defer { inOutputArguments = saved }
        var arguments: [Filter] = []
        while current.location.line == line, ![.endOfFile, .rightBrace, .rightParen].contains(current.kind) {
            arguments.append(try parseExpression())
        }
        return .comment(arguments)
    }

    // MARK: - Identifiers and keywords

    mutating func parseIdentifier(_ name: String) throws(CQLError) -> Filter {
        let token = current

        // Assignments and iteration on plain variables.
        if !Self.reservedWords.contains(name) {
            advance()
            return try parseVariableUse(name, token: token)
        }

        if Self.unsupportedFilters.contains(name) {
            throw error("the '\(name)' filter is not supported yet by this implementation", at: token)
        }

        if let type = Self.simpleKeywords[name] {
            advance()
            _ = type
            return .keyword(name)
        }

        if let (level, typeDirected, _) = Self.prefixFilters[name] {
            advance()
            return .prefix(name, try parseExpression(level, typeDirected: typeDirected))
        }

        if Self.directionNames.contains(name) {
            advance()
            let range = try parseOptionalSignedRange()
            return .direction(name, range: range, try parseExpression(Precedence.directionArgument))
        }

        if let kind = TransformKind(rawValue: name) {
            advance()
            let count = accept(keyword: "count")
            return .transform(kind, count: count, try parseExpression())
        }

        advance()
        switch name {
        case "not":
            return .not(try parseExpression(Precedence.notArgument))
        case "notransform":
            return .notransform(try parseExpression())
        case "if":
            let test = try parseExpression()
            _ = accept(keyword: "then")
            let consequent = try parseExpression()
            var alternative: Filter?
            if accept(keyword: "else") { alternative = try parseExpression() }
            return .ifThen(test, consequent, alternative)
        case "loop":
            return .loop(try parseExpression())
        case "while":
            try expect(.leftParen, "after 'while'")
            let test = try parseExpression()
            try expect(.rightParen, "after the while test")
            let body = try parseExpression()
            if case .binary(.regexMatch, let target, .string(let pattern)) = test {
                return .whileRegex(target: target, pattern: pattern, body: body)
            }
            return .whileLoop(test, body)
        case "assert":
            return .assert(try parseExpression())
        case "square", "piece":
            return try parseSquareOrPiece(isPiece: name == "piece")
        case "find":
            return try parseFind()
        case "echo":
            return try parseEcho()
        case "sort":
            return try parseSort()
        case "comment":
            return .comment(try parseOutputArguments())
        case "message":
            let quiet = accept(keyword: "quiet")
            return .message(quiet: quiet, try parseOutputArguments())
        case "str":
            return .call("str", try parseOutputArguments())
        case "between":
            return .call("between", try parseArgumentList(Precedence.setArgument, count: 2))
        case "max", "min":
            return .call(name, try parseArgumentList(Precedence.lowest))
        case "indexof":
            return .call("indexof", try parseArgumentList(Precedence.lowest, count: 2))
        case "lca", "distance", "ancestor", "descendant":
            return .call(name, try parseArgumentList(Precedence.lowest, count: 2))
        case "settag":
            let arguments = try parseArgumentList(Precedence.lowest, count: 2)
            return .setTag(arguments[0], arguments[1])
        case "makesquare":
            if current.kind == .leftParen {
                return .call("makesquare", try parseArgumentList(Precedence.numericArgument, count: 2))
            }
            return .prefix("makesquare", try parseExpression(Precedence.numericArgument, typeDirected: true))
        case "ray", "xray":
            var direction: String?
            if name == "ray", let word = current.identifier, Self.directionNames.contains(word) {
                direction = word
                advance()
            }
            return .ray(direction: direction, try parseArgumentList(Precedence.lowest), xray: name == "xray")
        case "pin":
            return try parsePin()
        case "child":
            if current.kind == .leftParen, !current.precededBySpace {
                return .child(try parseArgumentList(Precedence.lowest, count: 1)[0])
            }
            return .child(nil)
        case "position":
            return .position(try parseExpression(Precedence.numericArgument, typeDirected: true))
        case "legal", "pseudolegal", "currentmove":
            let source: MoveSource = name == "legal" ? .legal : name == "pseudolegal" ? .pseudolegal : .current
            let (dash, _) = try parseDashArgument(after: name)
            return .dash(dash, source: source)
        case "countmoves":
            var source = MoveSource.game
            if accept(keyword: "legal") { source = .legal } else if accept(keyword: "pseudolegal") { source = .pseudolegal }
            let (dash, _) = try parseDashArgument(after: name)
            return .countMoves(dash, source: source)
        case "dictionary", "local":
            if name == "local" { guard accept(keyword: "dictionary") else { throw error("expected 'dictionary' after 'local'") } }
            guard let dictionary = current.identifier else { throw error("expected a dictionary name") }
            dictionaries.insert(dictionary)
            let declaration = Filter.dictionaryDeclaration(name: dictionary, local: name == "local")
            if peek().kind == .leftBracket {
                advance()
                let assignment = try parseVariableUse(dictionary, token: token)
                return .compound([declaration, assignment])
            }
            advance()
            return declaration
        case "path":
            return try parsePath()
        case "consecutivemoves":
            var quiet = false
            var range: ClosedRange<Int>?
            while true {
                if accept(keyword: "quiet") { quiet = true; continue }
                if range == nil, integerLiteral() != nil { range = try parseOptionalRange(); continue }
                break
            }
            let arguments = try parseArgumentList(Precedence.lowest, count: 2)
            return .consecutiveMoves(quiet: quiet, range: range, arguments[0], arguments[1])
        case "focus":
            throw error("◎ (focus) can only be used as a ⊢ parameter", at: token)
        case "atomic":
            guard let variable = current.identifier, !Self.reservedWords.contains(variable) else {
                throw error("expected a variable name after 'atomic'")
            }
            advance()
            let op = try parseAssignmentOperator()
            let value = try parseExpression(op == .assign ? Precedence.relational : Precedence.numericArgument)
            if variableTypes[variable] == nil { variableTypes[variable] = typeOf(value) }
            return .atomic(variable, op, value)
        case "persistent":
            let quiet = accept(keyword: "quiet")
            guard let variable = current.identifier, !Self.reservedWords.contains(variable) else {
                throw error("expected a variable name after 'persistent'")
            }
            advance()
            let op = try parseAssignmentOperator()
            let value = try parseExpression(op == .assign ? Precedence.relational : Precedence.numericArgument)
            if variableTypes[variable] == nil { variableTypes[variable] = typeOf(value) }
            return .persistent(quiet: quiet, variable, op, value)
        case "unbind":
            guard let variable = current.identifier else { throw error("expected a variable after 'unbind'") }
            advance()
            if current.kind == .leftBracket {
                advance()
                let key = try parseExpression()
                try expect(.rightBracket, "after dictionary key")
                return .unbind(variable, key: key)
            }
            return .unbind(variable, key: nil)
        case "isbound", "isunbound":
            guard let variable = current.identifier else { throw error("expected a variable after '\(name)'") }
            advance()
            return .isBound(variable, negated: name == "isunbound")
        case "player":
            var color: CQLColor?
            if accept(keyword: "white") { color = .white } else if accept(keyword: "black") { color = .black }
            return implicitSearch(.tagValue(.player(color)))
        case "event": return implicitSearch(.tagValue(.event))
        case "site": return implicitSearch(.tagValue(.site))
        case "date": return implicitSearch(.tagValue(.date))
        case "eventdate": return implicitSearch(.tagValue(.eventdate))
        case "eco": return implicitSearch(.tagValue(.eco))
        case "tag":
            guard case .string(let tag) = current.kind else { throw error("tag expects a quoted tag name") }
            advance()
            return .tagValue(.tag(tag))
        case "elo":
            if accept(keyword: "white") { return .elo(.white) }
            if accept(keyword: "black") { return .elo(.black) }
            return .elo(nil)
        case "result":
            if case .string(let text) = current.kind {
                advance()
                return .result(text)
            }
            return .result(try parseResultText())
        case "fen":
            if case .string(let text) = current.kind, !inOutputArguments {
                advance()
                return .fenMatch(text)
            }
            return .keyword("fen")
        case "originalcomment", "hascomment":
            if case .string(let text) = current.kind, !inOutputArguments || name == "hascomment" {
                advance()
                return .originalComment(text)
            }
            if name == "hascomment" { throw error("hascomment expects a quoted string") }
            return .originalComment(nil)
        default:
            throw error("'\(name)' cannot be used here", at: token)
        }
    }

    mutating func implicitSearch(_ filter: Filter) -> Filter {
        if !inOutputArguments, case .string(let text) = current.kind {
            advance()
            return .binary(.in, .string(text), filter)
        }
        return filter
    }

    /// Handles everything that can follow a plain variable name.
    mutating func parseVariableUse(_ name: String, token: Token) throws(CQLError) -> Filter {
        switch current.kind {
        case .assign, .assignIfNonEmpty, .plusAssign, .minusAssign, .starAssign, .slashAssign, .percentAssign:
            let op = try parseAssignmentOperator()
            let isSimple = op == .assign || op == .assignIfNonEmpty
            let value = try parseExpression(isSimple ? Precedence.relational : Precedence.numericArgument,
                                            typeDirected: !isSimple)
            if isSimple, variableTypes[name] == nil || variableTypes[name] == .unknown {
                variableTypes[name] = typeOf(value)
            }
            return .assign(name, op, value)
        case .element:
            advance()
            if let dictionary = current.identifier, dictionaries.contains(dictionary) {
                advance()
                let saved = variableTypes[name]
                variableTypes[name] = .unknown
                let body = try parseExpression()
                variableTypes[name] = saved
                return .iterateDictionary(variable: name, dictionary: dictionary, body: body)
            }
            return try parseIterationBody(isPiece: false, all: false, variable: name)
        case .leftParen where functions[name] != nil && !current.precededBySpace:
            let definition = functions[name]!
            let arguments = try parseArgumentList(Precedence.lowest)
            guard arguments.count == definition.parameters.count else {
                throw error("function '\(name)' expects \(definition.parameters.count) argument(s), got \(arguments.count)", at: token)
            }
            guard !functionsBeingDefined.contains(name) else {
                throw error("recursive call of function '\(name)' is not allowed", at: token)
            }
            var mapping: [String: String] = [:]
            var prelude: [Filter] = []
            for (parameter, argument) in zip(definition.parameters, arguments) {
                if case .variable(let variable) = argument {
                    mapping[parameter] = variable
                } else {
                    hiddenVariableCounter += 1
                    let hidden = "__CQLarg\(hiddenVariableCounter)_\(parameter)"
                    mapping[parameter] = hidden
                    prelude.append(.assign(hidden, .assign, argument))
                }
            }
            let expanded = definition.body.renamingVariables(mapping)
            return prelude.isEmpty ? expanded : .compound(prelude + [expanded])
        case .leftBracket:
            // Subscript, possibly followed by an assignment.
            let saved = position
            let subscriptFilter = try parseSubscript(of: .variable(name))
            if current.kind == .assign, case .subscript(_, let key, let end, let isSlice) = subscriptFilter {
                advance()
                let value = try parseExpression(Precedence.relational)
                return .subscriptAssign(name, key: key ?? .number(0), end: end, isSlice: isSlice, value: value)
            }
            position = saved
            return .variable(name)
        default:
            if functions[name] != nil {
                throw error("function '\(name)' must be called with an argument list", at: token)
            }
            return .variable(name)
        }
    }

    mutating func parseAssignmentOperator() throws(CQLError) -> AssignmentOperator {
        let op: AssignmentOperator
        switch current.kind {
        case .assign: op = .assign
        case .assignIfNonEmpty: op = .assignIfNonEmpty
        case .plusAssign: op = .add
        case .minusAssign: op = .subtract
        case .starAssign: op = .multiply
        case .slashAssign: op = .divide
        case .percentAssign: op = .modulo
        default: throw error("expected an assignment operator")
        }
        advance()
        return op
    }

    /// `( a1 a2 … )`
    mutating func parseArgumentList(_ level: Int, count: Int? = nil) throws(CQLError) -> [Filter] {
        try expect(.leftParen, "to start the argument list")
        let saved = (colonDisabled, pathTopLevel)
        colonDisabled = 0
        pathTopLevel = false
        defer { (colonDisabled, pathTopLevel) = saved }
        var arguments: [Filter] = []
        while current.kind != .rightParen, current.kind != .endOfFile {
            arguments.append(try parseExpression(level))
        }
        try expect(.rightParen, "to close the argument list")
        if let count, arguments.count != count {
            throw error("expected \(count) argument(s), got \(arguments.count)")
        }
        return arguments
    }

    /// Arguments of `comment`, `message` and `str`: a list or a single filter.
    mutating func parseOutputArguments() throws(CQLError) -> [Filter] {
        let saved = inOutputArguments
        inOutputArguments = true
        defer { inOutputArguments = saved }
        if current.kind == .leftParen {
            return try parseArgumentList(Precedence.lowest)
        }
        return [try parseExpression(Precedence.numericArgument)]
    }

    /// `square [all] x in S body` or `piece [all] x in S body` / `piece x = S`.
    mutating func parseSquareOrPiece(isPiece: Bool) throws(CQLError) -> Filter {
        let all = accept(keyword: "all")
        guard let variable = current.identifier, !Self.reservedWords.contains(variable) else {
            throw error("expected a variable name")
        }
        advance()
        if isPiece, !all, accept(.assign) {
            variableTypes[variable] = .piece
            return .pieceAssign(variable, try parseExpression(Precedence.setArgument))
        }
        guard accept(keyword: "in") else { throw error("expected 'in' after the variable") }
        return try parseIterationBody(isPiece: isPiece, all: all, variable: variable)
    }

    mutating func parseFind() throws(CQLError) -> Filter {
        var quiet = false, backward = false
        var mode = FindMode.first
        while true {
            if accept(keyword: "quiet") { quiet = true; continue }
            if accept(keyword: "all") { mode = .all; continue }
            if accept(.lineBackward) { backward = true; continue }
            if integerLiteral() != nil, let range = try parseOptionalRange() { mode = .range(range); continue }
            break
        }
        return .find(quiet: quiet, mode: mode, backward: backward, try parseExpression())
    }

    mutating func parseEcho() throws(CQLError) -> Filter {
        let quiet = accept(keyword: "quiet")
        try expect(.leftParen, "after 'echo'")
        guard let source = current.identifier else { throw error("expected the echo source variable") }
        advance()
        guard let target = current.identifier else { throw error("expected the echo target variable") }
        advance()
        try expect(.rightParen, "after the echo variables")
        var includeSelf = false
        if current.identifier == "in", peek().identifier == "all" {
            advance()
            advance()
            includeSelf = true
        }
        let saved = (variableTypes[source], variableTypes[target])
        variableTypes[source] = .position
        variableTypes[target] = .position
        let body = try parseExpression()
        variableTypes[source] = saved.0
        variableTypes[target] = saved.1
        return .echo(source: source, target: target, includeSelf: includeSelf, quiet: quiet, body)
    }

    mutating func parseSort() throws(CQLError) -> Filter {
        var minimum = false, quiet = false
        var documentation: String?
        while true {
            if current.identifier == "min", peek().kind != .leftParen { advance(); minimum = true; continue }
            if accept(keyword: "quiet") { quiet = true; continue }
            if documentation == nil, case .string(let text) = current.kind { advance(); documentation = text; continue }
            break
        }
        return .sort(min: minimum, quiet: quiet, documentation: documentation, try parseExpression())
    }

    mutating func parsePin() throws(CQLError) -> Filter {
        var from: Filter?, through: Filter?, to: Filter?
        var role: String?
        while let word = current.identifier, ["from", "through", "to"].contains(word) {
            advance()
            let value = try parseExpression(Precedence.pinArgument)
            switch word {
            case "from": from = value
            case "through": through = value
            default: to = value
            }
            if role == nil { role = word }
        }
        return .pin(from: from, through: through, to: to, role: role ?? "through")
    }

    /// The dash argument of `legal`, `pseudolegal`, `currentmove`, `countmoves`.
    mutating func parseDashArgument(after name: String) throws(CQLError) -> (DashFilter, Bool) {
        let filter = try parseExpression(Precedence.dash)
        guard case .dash(let dash, .game) = filter else {
            throw error("'\(name)' must be followed by a ―― or × move filter")
        }
        return (dash, true)
    }

    /// Optional range made of integer literals, allowing negative values.
    mutating func parseOptionalSignedRange() throws(CQLError) -> ClosedRange<Int>? {
        func signedLiteral(_ parser: inout Parser) -> Int? {
            if case .integer(let value) = parser.current.kind {
                parser.advance()
                return value
            }
            if parser.current.kind == .minus, case .integer(let value) = parser.peek().kind, !parser.peek().precededBySpace {
                parser.advance()
                parser.advance()
                return -value
            }
            return nil
        }
        guard let low = signedLiteral(&self) else { return nil }
        let high = signedLiteral(&self) ?? low
        guard low <= high else { throw error("invalid range \(low) \(high)") }
        return low...high
    }

    // MARK: - Static types

    /// A best-effort static type, used for type-directed parsing decisions.
    func typeOf(_ filter: Filter) -> ValueType {
        switch filter {
        case .number, .captureGroupIndex, .cardinality, .negate, .countMoves, .elo, .consecutiveMoves:
            return .number
        case .string, .captureGroup, .tagValue:
            return .string
        case .pieceDesignator, .complement, .attackChain, .direction, .ray, .pin, .iterate(_, false, _, _, _):
            return .set
        case .variable(let name):
            return variableTypes[name] ?? .unknown
        case .keyword(let name):
            return name == "fen" ? .string : Self.simpleKeywords[name] ?? .unknown
        case .compound(let filters):
            return filters.last.map(typeOf) ?? .logical
        case .binary(let op, let lhs, let rhs):
            switch op {
            case .add:
                return typeOf(lhs) == .string || typeOf(rhs) == .string ? .string : .number
            case .subtract, .multiply, .divide, .modulo:
                return .number
            case .union, .intersection:
                return .set
            case .precedes, .succeeds, .precedesOrEqual, .succeedsOrEqual:
                return .position
            case .regexMatch:
                return .string
            case .in, .and, .or, .notEqual:
                return .logical
            case .equal, .less, .lessEqual, .greater, .greaterEqual:
                let left = typeOf(lhs)
                return left == .set && typeOf(rhs) == .set ? .logical : (left == .set ? .number : left)
            }
        case .at(_, let rhs):
            return typeOf(rhs)
        case .subscript(let target, _, _, _):
            if case .variable(let name) = target, dictionaries.contains(name) { return .unknown }
            return .string
        case .prefix(let name, let argument):
            if name == "ascii" { return typeOf(argument) == .string ? .number : .string }
            if name == "makesquare" { return .set }
            return Self.prefixFilters[name]?.2 ?? .unknown
        case .call(let name, let arguments):
            switch name {
            case "between", "makesquare": return .set
            case "indexof", "distance": return .number
            case "lca": return .position
            case "str": return .string
            case "max", "min": return arguments.first.map(typeOf) ?? .unknown
            default: return .logical
            }
        case .ifThen(_, let consequent, let alternative):
            let type = typeOf(consequent)
            return alternative.map { typeOf($0) == type ? type : .logical } ?? .logical
        case .dash(let dash, let source):
            if let last = dash.targets?.last { return typeOf(last) }
            return source == .current ? .logical : .set
        case .find(_, let mode, _, _):
            if case .first = mode { return .position }
            return .number
        case .child, .position:
            return .position
        case .transform(_, let count, let argument):
            return count ? .number : typeOf(argument)
        case .notransform(let argument), .sort(_, _, _, let argument):
            return typeOf(argument)
        case .originalComment(let text):
            return text == nil ? .string : .logical
        case .functionCall:
            return .unknown
        case .path(let path):
            return path.lastPosition ? .position : .number
        default:
            return .logical
        }
    }
}
