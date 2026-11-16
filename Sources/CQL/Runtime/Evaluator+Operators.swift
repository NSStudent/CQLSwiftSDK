import Foundation

extension Evaluator {
    // MARK: - Binary operators

    func evaluateBinary(_ op: BinaryOperator, _ lhs: Filter, _ rhs: Filter) throws(CQLError) -> Value? {
        switch op {
        case .and:
            guard try matches(lhs), try matches(rhs) else { return nil }
            return .matched
        case .or:
            if try matches(lhs) { return .matched }
            return try matches(rhs) ? .matched : nil
        case .notEqual:
            return try evaluateBinary(.equal, lhs, rhs) == nil ? .matched : nil
        case .in:
            guard let left = try evaluate(lhs), let right = try evaluate(rhs) else { return nil }
            switch (left, right) {
            case (.set(let a), .set(let b)): return a.isSubset(of: b) ? .matched : nil
            case (.string(let a), .string(let b)): return a.isEmpty || b.contains(a) ? .matched : nil
            default: throw runtimeError("'in' needs two sets or two strings")
            }
        case .regexMatch:
            guard let text = try evaluateString(lhs), case .string(let pattern) = rhs else { return nil }
            guard let match = try regexMatches(pattern, in: text, first: true).first else { return nil }
            captures = match
            return .string(match.first??.text ?? "")
        case .union, .intersection:
            let left = try evaluate(lhs)
            if op == .intersection, case .position(let a)? = left {
                guard let b = try evaluatePosition(rhs) else { return nil }
                return .set(positionalIntersection(a.node, b))
            }
            let a: SquareSet
            switch left {
            case .set(let set)?: a = set
            case nil: a = .empty
            case let other?: throw runtimeError("set operator applied to \(other)")
            }
            let b = try evaluateSet(rhs)
            return .set(op == .union ? a | b : a & b)
        case .precedes, .succeeds, .precedesOrEqual, .succeedsOrEqual:
            guard let a = try evaluatePosition(lhs), let b = try evaluatePosition(rhs) else { return nil }
            let holds: Bool
            switch op {
            case .precedes: holds = a !== b && a.isAncestor(of: b)
            case .precedesOrEqual: holds = a.isAncestor(of: b)
            case .succeeds: holds = a !== b && b.isAncestor(of: a)
            default: holds = b.isAncestor(of: a)
            }
            return holds ? .position(PositionRef(a)) : nil
        case .equal, .less, .lessEqual, .greater, .greaterEqual:
            guard var left = try evaluate(lhs), var right = try evaluate(rhs) else { return nil }
            switch (left, right) {
            case (.set(let a), .set(let b)):
                if op == .equal { return a == b ? .matched : nil }
                left = .number(a.count)
                right = .number(b.count)
            case (.set(let a), .number): left = .number(a.count)
            case (.number, .set(let b)): right = .number(b.count)
            default: break
            }
            let order: Int
            switch (left, right) {
            case (.number, .number), (.string, .string), (.position, .position):
                order = Self.compare(left, right)
            default:
                throw runtimeError("cannot compare \(left) with \(right)")
            }
            let holds: Bool
            switch op {
            case .equal: holds = order == 0
            case .less: holds = order < 0
            case .lessEqual: holds = order <= 0
            case .greater: holds = order > 0
            default: holds = order >= 0
            }
            return holds ? left : nil
        case .add, .subtract, .multiply, .divide, .modulo:
            guard let left = try evaluate(lhs), let right = try evaluate(rhs) else { return nil }
            switch (left, right) {
            case (.string(let a), .string(let b)) where op == .add:
                return .string(a + b)
            case (.number(let a), .number(let b)):
                return Self.arithmetic(op, a, b).map(Value.number)
            default:
                throw runtimeError("cannot apply \(op.rawValue) to \(left) and \(right)")
            }
        }
    }

    func positionalIntersection(_ a: PositionNode, _ b: PositionNode) -> SquareSet {
        var result = SquareSet()
        for square in 0..<64 where a.board.piece(at: square) == b.board.piece(at: square) {
            result.insert(square)
        }
        return result
    }

    // MARK: - Subscripts

    func evaluateSubscript(_ target: Filter, _ start: Filter?, _ end: Filter?, isSlice: Bool) throws(CQLError) -> Value? {
        if case .variable(let name) = target, let dictionary = dictionaries[name] {
            guard let start, let key = try evaluate(start) else { return nil }
            return dictionary[key]
        }
        guard let text = try evaluateString(target) else { return nil }
        let characters = Array(text)
        func index(_ filter: Filter?, default value: Int) throws(CQLError) -> Int? {
            guard let filter else { return value }
            guard let number = try evaluateNumber(filter) else { return nil }
            return number < 0 ? characters.count + number : number
        }
        if isSlice {
            guard var lower = try index(start, default: 0), var upper = try index(end, default: characters.count) else { return nil }
            lower = max(0, min(lower, characters.count))
            upper = max(0, min(upper, characters.count))
            return .string(lower < upper ? String(characters[lower..<upper]) : "")
        }
        guard let start, let position = try index(start, default: 0), characters.indices.contains(position) else { return nil }
        return .string(String(characters[position]))
    }

    func assignSubscript(_ name: String, key: Filter, end: Filter?, isSlice: Bool, value: Filter) throws(CQLError) -> Value? {
        if dictionaries[name] != nil {
            guard let keyValue = try evaluate(key), let entry = try evaluate(value) else { return nil }
            var stored = entry
            if case .variable(let source) = value, case .piece(let piece)? = variables[source] { stored = .piece(piece) }
            dictionaries[name]!.set(keyValue, stored)
            return .matched
        }
        guard case .string(let text)? = variables[name] else {
            throw runtimeError("\(name) is not a string variable or dictionary")
        }
        guard let replacement = try evaluateString(value) else { return nil }
        var characters = Array(text)
        func index(_ filter: Filter?, default value: Int) throws(CQLError) -> Int? {
            guard let filter else { return value }
            guard let number = try evaluateNumber(filter) else { return nil }
            return number < 0 ? characters.count + number : number
        }
        if isSlice {
            guard var lower = try index(key, default: 0), var upper = try index(end, default: characters.count) else { return nil }
            lower = max(0, min(lower, characters.count))
            upper = max(lower, min(upper, characters.count))
            characters.replaceSubrange(lower..<upper, with: Array(replacement))
        } else {
            guard let position = try index(key, default: 0), characters.indices.contains(position) else { return nil }
            characters.replaceSubrange(position...position, with: Array(replacement))
        }
        variables[name] = .string(String(characters))
        return .matched
    }

    // MARK: - Prefix filters and calls

    func evaluatePrefix(_ name: String, _ argument: Filter) throws(CQLError) -> Value? {
        switch name {
        case "abs":
            return try evaluateNumber(argument).map { .number(abs($0)) }
        case "sqrt":
            guard let number = try evaluateNumber(argument), number >= 0 else { return nil }
            return .number(Int(Double(number).squareRoot()))
        case "ascii":
            switch try evaluate(argument) {
            case .string(let text)?:
                guard text.count == 1, let ascii = text.unicodeScalars.first?.value else { return nil }
                return .number(Int(ascii))
            case .number(let code)?:
                guard (1...255).contains(code), let scalar = UnicodeScalar(code) else { return nil }
                return .string(String(Character(scalar)))
            default:
                return nil
            }
        case "int":
            guard let text = try evaluateString(argument), let number = Int(text) else { return nil }
            return .number(number)
        case "lowercase":
            return try evaluateString(argument).map { .string($0.lowercased()) }
        case "uppercase":
            return try evaluateString(argument).map { .string($0.uppercased()) }
        case "readfile":
            guard let path = try evaluateString(argument) else { return nil }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw runtimeError("cannot read file \(path)")
            }
            return .string(text)
        case "makesquare":
            guard let text = try evaluateString(argument), let square = SquareName.index(of: text) else { return nil }
            return .set(SquareSet(index: square))
        case "light":
            return .set(try evaluateSet(argument) & .light)
        case "dark":
            return .set(try evaluateSet(argument) & .dark)
        case "power":
            var total = 0
            for square in try evaluateSet(argument) { total += board.piece(at: square)?.kind.power ?? 0 }
            return .number(total)
        default:
            guard let square = try evaluateSet(argument).single else { return nil }
            let piece = board.piece(at: square)
            switch name {
            case "rank": return .number(square / 8 + 1)
            case "file": return .number(square % 8 + 1)
            case "type": return .number(piece.map { $0.kind.rawValue + 1 } ?? 0)
            case "colortype":
                guard let piece else { return .number(0) }
                return .number((piece.kind.rawValue + 1) * (piece.color == .white ? 1 : -1))
            case "typename": return .string(piece.map { String($0.kind.asciiLetter) } ?? "_")
            case "piecename": return .string(piece.map { String($0.asciiLetter) } ?? "_")
            case "pieceid": return current.pieceIDs[square].map(Value.number)
            default: throw runtimeError("unknown filter \(name)")
            }
        }
    }

    func evaluateCall(_ name: String, _ arguments: [Filter]) throws(CQLError) -> Value? {
        switch name {
        case "str":
            return .string(try arguments.map { (argument) throws(CQLError) -> String in try outputText(argument) }.joined())
        case "between":
            let a = try evaluateSet(arguments[0]), b = try evaluateSet(arguments[1])
            var result = SquareSet()
            for x in a { for y in b { result |= Attacks.between(x, y) } }
            return .set(result)
        case "max", "min":
            var best: Value?
            for argument in arguments {
                guard var value = try evaluate(argument) else { continue }
                if case .set(let set) = value { value = .number(set.count) }
                if let current = best {
                    let order = Self.compare(value, current)
                    if name == "max" ? order > 0 : order < 0 { best = value }
                } else {
                    best = value
                }
            }
            return best
        case "indexof":
            guard let needle = try evaluateString(arguments[0]), let haystack = try evaluateString(arguments[1]),
                  let range = haystack.range(of: needle) else { return nil }
            return .number(haystack.distance(from: haystack.startIndex, to: range.lowerBound))
        case "makesquare":
            guard let file = try evaluateNumber(arguments[0]), let rank = try evaluateNumber(arguments[1]),
                  (1...8).contains(file), (1...8).contains(rank) else { return nil }
            return .set(SquareSet(file: file - 1, rank: rank - 1))
        case "lca", "distance", "ancestor", "descendant":
            guard let a = try evaluatePosition(arguments[0]), let b = try evaluatePosition(arguments[1]) else { return nil }
            switch name {
            case "ancestor": return a !== b && a.isAncestor(of: b) ? .matched : nil
            case "descendant": return a !== b && b.isAncestor(of: a) ? .matched : nil
            default:
                let common = lowestCommonAncestor(a, b)
                if name == "lca" { return .position(PositionRef(common)) }
                return .number(a.ply - common.ply + b.ply - common.ply)
            }
        default:
            throw runtimeError("unknown filter \(name)")
        }
    }

    func lowestCommonAncestor(_ a: PositionNode, _ b: PositionNode) -> PositionNode {
        var x = a, y = b
        while x.ply > y.ply { x = x.parent! }
        while y.ply > x.ply { y = y.parent! }
        while x !== y {
            x = x.parent!
            y = y.parent!
        }
        return x
    }

    // MARK: - Strings and output

    /// Converts a filter to text as `str`, `comment` and `message` do.
    func outputText(_ filter: Filter) throws(CQLError) -> String {
        if case .variable(let name) = filter, case .piece(let piece)? = variables[name] {
            guard let square = current.square(ofPiece: piece.id), let occupant = board.piece(at: square) else {
                return "<captured>"
            }
            return "\(occupant.asciiLetter)\(SquareName.name(of: square))"
        }
        guard let value = try evaluate(filter) else {
            return "<false>"
        }
        switch value {
        case .matched: return "<true>"
        case .set(let set): return set.isEmpty ? "[]" : set.description
        case .number(let number): return String(number)
        case .string(let text): return text
        case .position(let position):
            let node = position.node
            let side = node.sideToMove == .white ? "wtm" : "btm"
            return node.isMainline ? "move \(node.moveNumber)(\(side))" : "move \(node.moveNumber)(\(side))[\(node.id)]"
        case .piece(let piece): return "piece#\(piece.id)"
        }
    }

    func outputValue(_ filter: Filter) throws(CQLError) -> String? {
        guard try evaluate(filter) != nil else { return nil }
        return try outputText(filter)
    }

    /// Regex matches as capture-group arrays (group 0 is the whole match).
    func regexMatches(_ pattern: String, in text: String, first: Bool = false) throws(CQLError) -> [[(text: String, index: Int)?]] {
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern)
        } catch {
            throw runtimeError("invalid regular expression \"\(pattern)\"")
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let results = first
            ? (expression.firstMatch(in: text, range: range).map { [$0] } ?? [])
            : expression.matches(in: text, range: range)
        return results.map { result in
            (0..<result.numberOfRanges).map { group in
                let groupRange = result.range(at: group)
                guard groupRange.location != NSNotFound else { return nil }
                return (nsText.substring(with: groupRange), groupRange.location)
            }
        }
    }

    // MARK: - Game metadata

    func evaluateTag(_ field: TagField) throws(CQLError) -> String? {
        let tags = game.tags
        switch field {
        case .player(nil):
            guard let white = tags["White"], let black = tags["Black"] else { return nil }
            return white + "\n" + black
        case .player(.white?): return tags["White"]
        case .player(.black?): return tags["Black"]
        case .event: return tags["Event"]
        case .site: return tags["Site"]
        case .date: return tags["Date"]
        case .eventdate: return tags["EventDate"]
        case .eco: return tags["ECO"]
        case .tag(let name): return tags[name]
        }
    }

    func evaluateElo(_ color: CQLColor?) -> Int? {
        let white = game.tags["WhiteElo"].flatMap { Int($0) }
        let black = game.tags["BlackElo"].flatMap { Int($0) }
        switch color {
        case .white?: return white
        case .black?: return black
        case nil:
            let known = [white, black].compactMap { $0 }
            return known.max()
        }
    }

    func fenMatches(_ pattern: String) -> Bool {
        let placement = pattern.split(separator: " ").first.map(String.init) ?? ""
        let rows = placement.split(separator: "/", omittingEmptySubsequences: false)
        guard rows.count == 8 else { return false }
        for (rowIndex, row) in rows.enumerated() {
            let rank = 7 - rowIndex
            var file = 0
            for character in row {
                if let skip = character.wholeNumberValue {
                    for _ in 0..<skip {
                        guard file < 8, board.piece(at: rank * 8 + file) == nil else { return false }
                        file += 1
                    }
                    continue
                }
                guard file < 8 else { return false }
                let occupant = board.piece(at: rank * 8 + file)
                switch character {
                case ".": break
                case "_": if occupant != nil { return false }
                case "A": if occupant?.color != .white { return false }
                case "a": if occupant?.color != .black { return false }
                default:
                    guard let types = PieceTypeSet(character: character), let occupant, types.contains(occupant) else { return false }
                }
                file += 1
            }
            guard file == 8 else { return false }
        }
        return true
    }

    static let symbolicNAGs: [String: Int] = [
        "!": 1, "?": 2, "!!": 3, "??": 4, "!?": 5, "?!": 6, "=": 10, "+/=": 14, "=/+": 15,
        "+/-": 16, "-/+": 17, "+-": 18, "-+": 19,
    ]

    func evaluateOriginalComment(_ literal: String?) -> Value? {
        let comment = current.originalComments.joined(separator: " ")
        guard let literal else {
            return comment.isEmpty ? nil : .string(comment)
        }
        if literal.hasPrefix("$"), let code = Int(literal.dropFirst()) {
            return current.nags.contains(code) ? .matched : nil
        }
        if let code = Self.symbolicNAGs[literal] {
            return current.nags.contains(code) ? .matched : nil
        }
        return !comment.isEmpty && comment.contains(literal) ? .matched : nil
    }
}
