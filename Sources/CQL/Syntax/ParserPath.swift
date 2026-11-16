extension Parser {
    /// Parses `⊢ parameters constituents` (the `path` keyword is already consumed).
    mutating func parsePath() throws(CQLError) -> Filter {
        let start = current
        let savedTopLevel = pathTopLevel
        pathTopLevel = true
        defer { pathTopLevel = savedTopLevel }

        var path = PathFilter()
        parameters: while true {
            switch current.kind {
            case .identifier("primary"): advance(); path.primary = true
            case .identifier("focus"):
                advance()
                path.focusCapture = accept(keyword: "capture")
                path.focus = try parseExpression(Precedence.union)
            case .identifier("max") where peek().kind != .leftParen:
                advance()
                path.maximize = try parseExpression(Precedence.numericArgument)
            case .identifier("verbose"): advance(); path.verbose = true
            case .identifier("keepallbest"): advance(); path.keepAllBest = true
            case .identifier("piecepath"): advance(); path.piecePath = true
            case .identifier("quiet"): advance(); path.quiet = true
            case .identifier("nestban"): advance(); path.nestBan = true
            case .identifier("firstmatch"): advance(); path.firstMatch = true
            case .identifier("lastposition"): advance(); path.lastPosition = true
            case .identifier("title"):
                advance()
                guard case .string(let text) = current.kind else { throw error("title expects a string literal") }
                advance()
                path.title = text
            case .string(let text) where path.title == nil:
                // A bare string literal among the parameters is the title.
                advance()
                path.title = text
            default:
                break parameters
            }
        }
        path.constituents = try parsePathConstituents(isChain: false)
        guard !path.constituents.isEmpty else {
            throw error("⊢ needs at least one constituent", at: start)
        }
        return .path(path)
    }

    /// Constituents until a closing bracket, end of file or a blank line.
    mutating func parsePathConstituents(isChain: Bool) throws(CQLError) -> [PathConstituent] {
        var items: [PathConstituent] = []
        while true {
            let token = current
            if [.rightBrace, .rightParen, .endOfFile].contains(token.kind) { break }
            if !items.isEmpty, token.precededByBlankLine { break }

            if let (minimum, maximum) = try parseRepetitionSignal() {
                guard !items.isEmpty else { throw error("repetition signal without a constituent", at: token) }
                let group = try repetitionGroup(&items, at: token)
                items.append(.repetition(group, minimum: minimum, maximum: maximum))
                continue
            }

            if token.kind == .leftParen {
                advance()
                let chain = try parsePathConstituents(isChain: true)
                try expect(.rightParen, "to close the ⊢ chain")
                guard !chain.isEmpty else { throw error("empty ⊢ chain", at: token) }
                items.append(.chain(chain))
                continue
            }

            guard canStartOperand(token) || token.kind == .annotation else { break }
            let filter = try parseExpression()
            if case .dash(let dash, .game) = filter, dash.targets == nil {
                items.append(.move(dash))
            } else {
                items.append(.filter(filter))
            }
        }
        return items
    }

    /// `*`, `+`, `?`, `{n}`, `{n,}`, `{,n}`, `{m,n}`.
    mutating func parseRepetitionSignal() throws(CQLError) -> (Int, Int?)? {
        switch current.kind {
        case .star: advance(); return (0, nil)
        case .plus: advance(); return (1, nil)
        case .question: advance(); return (0, 1)
        case .leftBrace:
            guard let (low, high, sawComma, offset) = braceRepetition() else { return nil }
            for _ in 0...offset { advance() }
            let minimum = low ?? 0
            let maximum: Int? = sawComma ? high : low
            if let maximum, maximum < minimum { throw error("invalid repetition {\(minimum),\(maximum)}") }
            return (minimum, maximum)
        default:
            return nil
        }
    }

    /// Recognises `{n}`, `{n,}`, `{,n}`, `{m,n}` at the current token without consuming it.
    func braceRepetition() -> (Int?, Int?, Bool, Int)? {
        guard current.kind == .leftBrace else { return nil }
        var offset = 1
        var low: Int?, high: Int?
        var sawComma = false
        if case .integer(let value) = peek(offset).kind { low = value; offset += 1 }
        if peek(offset).kind == .comma { sawComma = true; offset += 1 }
        if sawComma, case .integer(let value) = peek(offset).kind { high = value; offset += 1 }
        guard peek(offset).kind == .rightBrace, low != nil || high != nil else { return nil }
        return (low, high, sawComma, offset)
    }

    /// Removes and returns the group a repetition applies to: a chain, or the
    /// most recent ―― constituent followed by filter constituents.
    mutating func repetitionGroup(_ items: inout [PathConstituent], at token: Token) throws(CQLError) -> [PathConstituent] {
        if case .chain(let chain)? = items.last {
            guard chain.containsMove else { throw error("a repeated ⊢ chain must contain a ―― constituent", at: token) }
            items.removeLast()
            return chain
        }
        var index = items.count - 1
        while index >= 0, case .filter = items[index] { index -= 1 }
        guard index >= 0, case .move = items[index] else {
            throw error("a repetition needs a preceding ―― constituent", at: token)
        }
        let group = Array(items[index...])
        items.removeSubrange(index...)
        return group
    }
}

extension Array where Element == PathConstituent {
    var containsMove: Bool {
        contains { constituent in
            switch constituent {
            case .move: true
            case .filter: false
            case .chain(let items), .repetition(let items, _, _): items.containsMove
            }
        }
    }
}
