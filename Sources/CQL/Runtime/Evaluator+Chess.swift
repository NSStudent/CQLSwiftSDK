extension Evaluator {
    // MARK: - Keywords

    func evaluateKeyword(_ name: String) throws(CQLError) -> Value? {
        let node = current!
        switch name {
        case "true": return .matched
        case "false": return nil
        case "check": return board.isInCheck(.white) || board.isInCheck(.black) ? .matched : nil
        case "mate": return node.isMate ? .matched : nil
        case "stalemate": return node.isStalemate ? .matched : nil
        case "wtm": return node.sideToMove == .white ? .matched : nil
        case "btm": return node.sideToMove == .black ? .matched : nil
        case "white": return .number(1)
        case "black": return .number(-1)
        case "sidetomove": return .number(node.sideToMove == .white ? 1 : -1)
        case "ply": return .number(node.ply)
        case "positionid": return .number(node.id)
        case "movenumber": return .number(node.moveNumber)
        case "depth": return .number(node.depth)
        case "mainline": return node.isMainline ? .matched : nil
        case "variation": return node.isMainline ? nil : .matched
        case "virtualmainline": return isVirtualMainline(node) ? .matched : nil
        case "terminal": return children(of: node).isEmpty ? .matched : nil
        case "initial": return node.isInitial ? .matched : nil
        case "gamenumber": return .number(game.gameNumber)
        case "lastgamenumber": return .number(lastGameNumber)
        case "year":
            guard let date = game.tags["Date"], date.count >= 4, let year = Int(date.prefix(4)) else { return nil }
            return .number(year)
        case "pathstart", "pathlastposition", "pathcount", "pathcountunfocused": return evaluatePathStatus(name)
        case "currentposition": return .position(PositionRef(node))
        case "initialposition": return .position(PositionRef(game.root))
        case "parent": return node.parent.map { .position(PositionRef($0)) }
        case "currenttransform": return .string("<>")
        case "fen": return .string(board.fen)
        case "removecomment":
            removedComments.insert(node.id)
            return .matched
        case "try":
            var whiteSecondaries = 0
            var cursor: PositionNode? = node
            while let position = cursor, let parent = position.parent {
                if parent.sideToMove == .white, position.childIndex > 0 { whiteSecondaries += 1 }
                cursor = parent
            }
            return whiteSecondaries == 1 ? .matched : nil
        // Current move filters
        case "from", "to":
            guard let move = node.move else { return .set(.empty) }
            return .set(contextualSquares(of: move, origin: name == "from"))
        case "enpassant": return node.move?.isEnPassant == true ? .matched : nil
        case "enpassantsquare":
            guard let move = node.move, move.isEnPassant, let square = move.captureSquare else { return .set(.empty) }
            return .set(SquareSet(index: square))
        case "nullmove": return node.move?.isNull == true ? .matched : nil
        case "primary": return node.move != nil && node.childIndex == 0 ? .matched : nil
        case "secondary": return node.move != nil && node.childIndex > 0 ? .matched : nil
        case "o-o": return node.move?.castling == .kingside ? .matched : nil
        case "o-o-o": return node.move?.castling == .queenside ? .matched : nil
        case "castle": return node.move?.castling != nil ? .matched : nil
        // Pure, model and ideal mates and stalemates (participants, or ∅)
        case "puremate", "modelmate", "idealmate":
            guard node.isMate, let participants = board.pureMateParticipants() else { return .set(.empty) }
            if name == "puremate" { return .set(participants) }
            return .set(board.refine(participants, model: name == "modelmate"))
        case "purestalemate", "modelstalemate", "idealstalemate":
            guard node.isStalemate, let participants = board.pureStalemateParticipants() else { return .set(.empty) }
            if name == "purestalemate" { return .set(participants) }
            return .set(board.refine(participants, model: name == "modelstalemate"))
        // Pawn structure (colour symmetric, unaffected by transforms)
        case "passedpawns": return .set(passedPawns())
        case "doubledpawns": return .set(pawnStructure { color, pawns, file in (pawns & SquareSet.file(file)).count > 1 })
        case "isolatedpawns", "connectedpawns":
            let connected = pawnStructure { color, pawns, file in
                let neighbours = (file > 0 ? SquareSet.file(file - 1) : .empty) | (file < 7 ? SquareSet.file(file + 1) : .empty)
                return !(pawns & neighbours).isEmpty
            }
            let allPawns = board.squares(of: CQLPiece(.pawn, .white)) | board.squares(of: CQLPiece(.pawn, .black))
            return .set(name == "connectedpawns" ? connected : allPawns & ~connected)
        default:
            throw runtimeError("unknown filter \(name)")
        }
    }

    var lastGameNumber: Int { lastGameNumberValue }

    func isVirtualMainline(_ node: PositionNode) -> Bool {
        var cursor: PositionNode? = node
        while let position = cursor, let parent = position.parent {
            if parent.sideToMove == .white, position.childIndex > 0 { return false }
            cursor = parent
        }
        return true
    }

    /// `from`/`to` of the current move, honouring contextual castling.
    func contextualSquares(of move: MoveInfo, origin: Bool) -> SquareSet {
        guard let rook = move.castlingRook, let last = dashScopes.last, let scope = last else {
            return origin ? move.fromSquares : move.toSquares
        }
        // Pieces are identified in the current position (the tail of the move).
        func focused(_ square: Int) -> Bool {
            guard let focus = scope.focus else { return true }
            return current.pieceID(at: square).map(focus.contains) ?? false
        }
        var result = SquareSet()
        if scope.left.contains(move.from), scope.right.contains(move.to), focused(move.to) {
            result.insert(origin ? move.from : move.to)
        }
        if scope.left.contains(rook.from), scope.right.contains(rook.to), focused(rook.to) {
            result.insert(origin ? rook.from : rook.to)
        }
        return result
    }

    /// Pawns (of both colours) for which `predicate(color, ownPawns, file)` holds.
    func pawnStructure(_ predicate: (CQLColor, SquareSet, Int) -> Bool) -> SquareSet {
        var result = SquareSet()
        for color in [CQLColor.white, .black] {
            let pawns = board.squares(of: CQLPiece(.pawn, color))
            for square in pawns where predicate(color, pawns, square % 8) { result.insert(square) }
        }
        return result
    }

    func passedPawns() -> SquareSet {
        var result = SquareSet()
        for color in [CQLColor.white, .black] {
            let enemyPawns = board.squares(of: CQLPiece(.pawn, color.opposite))
            for square in board.squares(of: CQLPiece(.pawn, color)) {
                let file = square % 8, rank = square / 8
                var blocked = false
                for enemy in enemyPawns where abs(enemy % 8 - file) <= 1 {
                    if color == .white ? enemy / 8 > rank : enemy / 8 < rank { blocked = true; break }
                }
                if !blocked { result.insert(square) }
            }
        }
        return result
    }

    // MARK: - Attacks

    func evaluateAttackChain(_ written: [Filter], reversed: Bool) throws(CQLError) -> SquareSet {
        var sets: [SquareSet] = []
        for operand in written { sets.append(try evaluateSet(operand)) }
        if reversed { sets.reverse() }
        if sets.count == 2 {
            let occupied = board.occupied
            if reversed {
                // Y ← X: squares of Y attacked by a piece on X.
                var attacked = SquareSet()
                for from in sets[0] where occupied.contains(from) { attacked |= board.attacks(from: from) }
                return sets[1] & attacked
            }
            var result = SquareSet()
            for from in sets[0] where occupied.contains(from) && !(board.attacks(from: from) & sets[1]).isEmpty {
                result.insert(from)
            }
            return result
        }
        // n-ary chain: x1 is a line piece that would attack xn if x2…x(n-1) were empty.
        var starts = SquareSet(), ends = SquareSet()
        let occupied = board.occupied
        for start in sets[0] {
            guard let piece = board.piece(at: start), [.bishop, .rook, .queen].contains(piece.kind) else { continue }
            let directions: [BoardDirection] = piece.kind == .rook ? BoardDirection.orthogonal
                : piece.kind == .bishop ? BoardDirection.diagonal : BoardDirection.allCases
            for direction in directions {
                var line: [Int] = []
                var square = start
                while let next = Attacks.step(square, direction) { line.append(next); square = next }
                let found = chainEnds(line, 0, sets, 1, occupied)
                if !found.isEmpty {
                    starts.insert(start)
                    ends |= found
                }
            }
        }
        return reversed ? ends : starts
    }

    /// Ends of chain completions along `line` from `position`, needing operand `k` next.
    private func chainEnds(_ line: [Int], _ position: Int, _ sets: [SquareSet], _ k: Int, _ occupied: SquareSet) -> SquareSet {
        guard position < line.count else { return .empty }
        let square = line[position]
        var result = SquareSet()
        if k == sets.count - 1 {
            if sets[k].contains(square) { result.insert(square) }
        } else if sets[k].contains(square) {
            result |= chainEnds(line, position + 1, sets, k + 1, occupied)
        }
        if !occupied.contains(square) {
            result |= chainEnds(line, position + 1, sets, k, occupied)
        }
        return result
    }

    func evaluateDirection(_ name: String, range: ClosedRange<Int>?, _ argument: Filter) throws(CQLError) -> SquareSet {
        guard let directions = BoardDirection.named(name) else { throw runtimeError("unknown direction \(name)") }
        let squares = try evaluateSet(argument)
        let distances = range ?? 1...7
        var result = SquareSet()
        for square in squares {
            for direction in directions {
                for distance in distances {
                    var target: Int? = square
                    let step = distance >= 0 ? direction : direction.opposite
                    for _ in 0..<abs(distance) { target = target.flatMap { Attacks.step($0, step) } }
                    if let target { result.insert(target) }
                }
            }
        }
        return result
    }

    func evaluateRay(direction: String?, _ filters: [Filter], xray: Bool) throws(CQLError) -> SquareSet {
        var sets: [SquareSet] = []
        for filter in filters { sets.append(try evaluateSet(filter)) }
        guard sets.count >= 2 else { throw runtimeError("ray needs at least two arguments") }
        if xray {
            let lines = board.squares(of: PieceTypeSet(character: "R")!.union(PieceTypeSet(character: "r")!)
                .union(PieceTypeSet(character: "Q")!).union(PieceTypeSet(character: "q")!))
            let diagonals = board.squares(of: PieceTypeSet(character: "B")!.union(PieceTypeSet(character: "b")!)
                .union(PieceTypeSet(character: "Q")!).union(PieceTypeSet(character: "q")!))
            var orthogonalSets = sets, diagonalSets = sets
            orthogonalSets[0] &= lines
            diagonalSets[0] &= diagonals
            return rayEnds(BoardDirection.orthogonal, orthogonalSets) | rayEnds(BoardDirection.diagonal, diagonalSets)
        }
        let directions = direction.flatMap(BoardDirection.named) ?? BoardDirection.allCases
        return rayEnds(directions, sets)
    }

    private func rayEnds(_ directions: [BoardDirection], _ sets: [SquareSet]) -> SquareSet {
        let occupied = board.occupied
        var result = SquareSet()
        for start in sets[0] {
            for direction in directions {
                var line: [Int] = []
                var square = start
                while let next = Attacks.step(square, direction) { line.append(next); square = next }
                result |= raySearch(line, 0, sets, 1, occupied)
            }
        }
        return result
    }

    private func raySearch(_ line: [Int], _ position: Int, _ sets: [SquareSet], _ k: Int, _ occupied: SquareSet) -> SquareSet {
        guard position < line.count else { return .empty }
        let square = line[position]
        var result = SquareSet()
        if sets[k].contains(square) {
            if k == sets.count - 1 {
                result.insert(square)
            } else {
                result |= raySearch(line, position + 1, sets, k + 1, occupied)
            }
        }
        if !occupied.contains(square) {
            result |= raySearch(line, position + 1, sets, k, occupied)
        }
        return result
    }

    func evaluatePin(from: Filter?, through: Filter?, to: Filter?, role: String) throws(CQLError) -> SquareSet {
        let anyPiece = board.occupied
        let fromSet = try from.map { (f) throws(CQLError) -> SquareSet in try evaluateSet(f) } ?? anyPiece
        let throughSet = try through.map { (f) throws(CQLError) -> SquareSet in try evaluateSet(f) } ?? anyPiece
        let toSet = try to.map { (f) throws(CQLError) -> SquareSet in try evaluateSet(f) }
            ?? board.squares(of: CQLPiece(.king, .white)) | board.squares(of: CQLPiece(.king, .black))
        let occupied = board.occupied
        var result = SquareSet()
        for pinner in fromSet {
            guard let piece = board.piece(at: pinner), [.bishop, .rook, .queen].contains(piece.kind) else { continue }
            let directions: [BoardDirection] = piece.kind == .rook ? BoardDirection.orthogonal
                : piece.kind == .bishop ? BoardDirection.diagonal : BoardDirection.allCases
            for direction in directions {
                var square = pinner
                var pinned: Int?
                while let next = Attacks.step(square, direction) {
                    square = next
                    if pinned == nil {
                        guard occupied.contains(next) else { continue }
                        guard let target = board.piece(at: next), target.color != piece.color, throughSet.contains(next) else { break }
                        pinned = next
                        continue
                    }
                    let occupant = board.piece(at: next)
                    if let occupant, occupant.color != board.piece(at: pinned!)!.color { break }
                    if toSet.contains(next) {
                        switch role {
                        case "from": result.insert(pinner)
                        case "to": result.insert(next)
                        default: result.insert(pinned!)
                        }
                    }
                    if occupant != nil { break }
                }
            }
        }
        return result
    }

    // MARK: - Moves

    /// Moves considered by a dash filter, paired with the position after the move when it is in the game tree.
    func candidateMoves(_ source: MoveSource) -> [(MoveInfo, PositionNode?)] {
        switch source {
        case .game:
            return children(of: current).compactMap { child in child.move.map { ($0, child) } }
        case .current:
            guard let move = current.move else { return [] }
            return [(move, current)]
        case .legal:
            return current.legalMoves.map { ($0, nil) }
        case .pseudolegal:
            return current.board.pseudolegalMoves().map { ($0, nil) }
        }
    }

    /// Moves matching a dash, with the value of its last target (if any).
    func matchingMoves(_ dash: DashFilter, source: MoveSource, stopAtFirst: Bool) throws(CQLError) -> [(MoveInfo, Value?)] {
        let head: PositionNode = source == .current ? (current.parent ?? current) : current
        guard source != .current || current.parent != nil else { return [] }
        let (left, right) = try at(head, barrier: false) { () throws(CQLError) -> (SquareSet, SquareSet) in
            (try dash.left.map { (f) throws(CQLError) -> SquareSet in try evaluateSet(f) } ?? .all,
             try dash.right.map { (f) throws(CQLError) -> SquareSet in try evaluateSet(f) } ?? .all)
        }
        guard let promotion = try promotionTypes(dash, at: head) else { return [] }
        var result: [(MoveInfo, Value?)] = []
        var countedPromotions: Set<Int> = []
        for (move, child) in candidateMoves(source) {
            guard let moved = movedSquares(dash, move, left: left, right: right, promotion: promotion) else { continue }
            var value: Value? = .set(moved)
            if let targets = dash.targets {
                if let child {
                    dashScopes.append(DashScope(left: left, right: right, focus: nil))
                    defer { dashScopes.removeLast() }
                    value = try at(child, barrier: false) { () throws(CQLError) -> Value? in try evaluate(.compound(targets)) }
                    guard let matched = value, matched.matches else { continue }
                } else {
                    guard targets.allSatisfy({ generatedMoveSatisfies(move, $0) }) else { continue }
                    value = .matched
                }
            }
            if source == .legal || source == .pseudolegal, promotion == nil, move.promotion != nil {
                // Promotions differing only by piece count as one move.
                let key = move.from * 64 + move.to
                if !countedPromotions.insert(key).inserted { continue }
            }
            result.append((move, value))
            if stopAtFirst, dash.targets != nil { break }
        }
        return result
    }

    /// The promotion constraint of a dash: `.some(nil)` when there is none,
    /// `nil` when a promotion filter fails to match.
    func promotionTypes(_ dash: DashFilter, at head: PositionNode) throws(CQLError) -> PieceTypeSet?? {
        guard let filter = dash.promotionFilter else { return .some(dash.promotion) }
        guard let text = try at(head, barrier: false, { () throws(CQLError) -> String? in try evaluateString(filter) }) else {
            return nil
        }
        var types = PieceTypeSet()
        for character in text {
            guard let simple = PieceTypeSet(character: character) else { throw runtimeError("invalid promotion type \"\(text)\"") }
            types.formUnion(simple)
        }
        return .some(types)
    }

    /// Origin squares of the pieces of `move` that satisfy the dash's left,
    /// right, capture and promotion parts; `nil` if the move does not match.
    func movedSquares(_ dash: DashFilter, _ move: MoveInfo, left: SquareSet, right: SquareSet,
                      promotion: PieceTypeSet?) -> SquareSet? {
        var moved = SquareSet()
        if left.contains(move.from), right.contains(move.to) { moved.insert(move.from) }
        if let rook = move.castlingRook, left.contains(rook.from), right.contains(rook.to) { moved.insert(rook.from) }
        guard !moved.isEmpty else { return nil }
        if dash.isCapture, move.captured == nil { return nil }
        if let promotion {
            guard let kind = move.promotion,
                  promotion.contains(CQLPiece(kind, .white)) || promotion.contains(CQLPiece(kind, .black)) else { return nil }
        }
        return moved
    }

    /// Target filters allowed on generated (legal/pseudolegal) moves.
    private func generatedMoveSatisfies(_ move: MoveInfo, _ target: Filter) -> Bool {
        switch target {
        case .keyword("o-o"): return move.castling == .kingside
        case .keyword("o-o-o"): return move.castling == .queenside
        case .keyword("castle"): return move.castling != nil
        case .keyword("enpassant"): return move.isEnPassant
        default: return false
        }
    }

    func evaluateDash(_ dash: DashFilter, source: MoveSource) throws(CQLError) -> Value? {
        let moves = try matchingMoves(dash, source: source, stopAtFirst: true)
        guard let first = moves.first else { return dash.targets == nil && source != .current ? .set(.empty) : nil }
        if source == .current { return .matched }
        if dash.targets != nil { return first.1 }
        var origins = SquareSet()
        for (_, value) in moves { if case .set(let set)? = value { origins |= set } }
        return .set(origins)
    }

    // MARK: - Searching

    /// The current position and its visible descendants, in PGN order.
    func descendants(of node: PositionNode) -> [PositionNode] {
        PositionNode.pgnOrder(from: node) { children(of: $0) }
    }

    func evaluateFind(quiet: Bool, mode: FindMode, backward: Bool, _ inner: Filter) throws(CQLError) -> Value? {
        var candidates: [PositionNode] = []
        if backward {
            var cursor: PositionNode? = current
            while let node = cursor { candidates.append(node); cursor = node.parent }
        } else {
            candidates = descendants(of: current)
        }
        var count = 0
        for node in candidates {
            let matched = try at(node) { () throws(CQLError) -> Bool in try matches(inner) }
            guard matched else { continue }
            if case .first = mode { return .position(PositionRef(node)) }
            count += 1
        }
        switch mode {
        case .first: return nil
        case .all: return count > 0 ? .number(count) : nil
        case .range(let range): return range.contains(count) ? .number(count) : nil
        }
    }

    /// Length of the longest run of identical consecutive moves on the two
    /// lines from the latest common ancestor of `first` and `second`.
    func evaluateConsecutiveMoves(quiet: Bool, range: ClosedRange<Int>?, _ first: Filter, _ second: Filter) throws(CQLError) -> Value? {
        guard let x = try evaluatePosition(first), let y = try evaluatePosition(second) else { return nil }
        let ancestor = lowestCommonAncestor(x, y)
        func line(to node: PositionNode) -> [PositionNode] {
            var result: [PositionNode] = []
            var cursor = node
            while cursor !== ancestor, let parent = cursor.parent {
                result.append(cursor)
                cursor = parent
            }
            return result.reversed()
        }
        func key(_ node: PositionNode) -> Int {
            guard let move = node.move else { return -1 }
            return (move.from * 64 + move.to) * 8 + (move.promotion.map { $0.rawValue + 1 } ?? 0)
        }
        let s = line(to: x).map { ($0, key($0)) }
        let t = line(to: y).map { ($0, key($0)) }
        // Longest common substring (dynamic programming over suffix lengths).
        var best = 0, endS = 0, endT = 0
        var previous = Array(repeating: 0, count: t.count + 1)
        for i in 0..<s.count {
            var row = Array(repeating: 0, count: t.count + 1)
            for j in 0..<t.count where s[i].1 == t[j].1 {
                row[j + 1] = previous[j] + 1
                if row[j + 1] > best { (best, endS, endT) = (row[j + 1], i, j) }
            }
            previous = row
        }
        if let range, !range.contains(best) { return nil }
        if best > 0, !quiet, !program.header.quiet {
            func name(_ filter: Filter, _ fallback: String) -> String {
                if case .variable(let variable) = filter { return variable }
                return fallback
            }
            let firstName = name(first, "first"), secondName = name(second, "second")
            for index in 0..<best {
                let a = s[endS - best + 1 + index].0, b = t[endT - best + 1 + index].0
                comments.append(GeneratedComment(positionID: a.id, path: a.path, text: "\(firstName)-move[\(index + 1)]"))
                comments.append(GeneratedComment(positionID: b.id, path: b.path, text: "\(secondName)-move[\(index + 1)]"))
            }
        }
        return .number(best)
    }

    func evaluateEcho(source: String, target: String, includeSelf: Bool, quiet: Bool, _ inner: Filter) throws(CQLError) -> Value? {
        let saved = (variables[source], variables[target])
        defer {
            variables[source] = saved.0
            variables[target] = saved.1
        }
        let origin = current!
        variables[source] = .position(PositionRef(origin))
        var matched = false
        var best: Value?
        for node in visiblePositions where includeSelf || node !== origin {
            variables[target] = .position(PositionRef(node))
            guard let value = try at(node, { () throws(CQLError) -> Value? in try evaluate(inner) }), value.matches else { continue }
            matched = true
            if case .number = value, best == nil || Self.compare(value, best!) > 0 { best = value }
        }
        guard matched else { return nil }
        return best ?? .matched
    }
}

extension BoardDirection {
    var opposite: BoardDirection {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        case .northeast: .southwest
        case .southwest: .northeast
        case .northwest: .southeast
        case .southeast: .northwest
        }
    }
}
