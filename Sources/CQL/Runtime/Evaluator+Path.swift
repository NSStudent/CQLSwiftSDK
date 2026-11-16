/// Context for contextual `from`/`to` (castling) inside a ―― scope.
struct DashScope {
    var left: SquareSet
    var right: SquareSet
    /// Focused piece identities of the enclosing ⊢, if it has ◎.
    var focus: Set<Int>?
}

/// State of a ⊢ filter while it is being matched.
struct PathState {
    let start: PositionNode
    var count: Int
}

extension Evaluator {
    private typealias Continuation = (PositionNode, Int, [PositionNode], DashScope?) throws(CQLError) -> Void

    private final class Search {
        let path: PathFilter
        let start: PositionNode
        let focus: Set<Int>?
        let commentMark: Int
        var best: [Candidate] = []
        var stop = false

        struct Candidate {
            var end: PositionNode
            var count: Int
            var nodes: [PositionNode]
            var comments: [GeneratedComment]
            var atomics: [String: Value]
            var score: Value?
        }

        init(path: PathFilter, start: PositionNode, focus: Set<Int>?, commentMark: Int) {
            self.path = path
            self.start = start
            self.focus = focus
            self.commentMark = commentMark
        }
    }

    func evaluatePath(_ path: PathFilter) throws(CQLError) -> Value? {
        let start = current!
        if path.nestBan, nestBans[path]?.contains(ObjectIdentifier(start)) == true { return nil }

        var focus: Set<Int>?
        if let focusFilter = path.focus {
            focus = Set(try evaluateSet(focusFilter).compactMap { start.pieceID(at: $0) })
        }
        let search = Search(path: path, start: start, focus: focus, commentMark: comments.count)
        let savedAtomics = atomicSnapshot()
        pathStack.append(PathState(start: start, count: 0))
        defer { pathStack.removeLast() }

        try matchSequence(path.constituents[...], search, start, 0, [start], nil) { (end, count, nodes, _) throws(CQLError) in
            try self.complete(search, end, count, nodes)
        }
        comments.removeSubrange(search.commentMark...)
        guard let best = search.best.first else {
            restoreAtomics(savedAtomics)
            return nil
        }

        restoreAtomics(best.atomics)
        for candidate in path.keepAllBest ? search.best : [best] {
            comments.append(contentsOf: candidate.comments)
        }
        if !path.quiet, !program.header.quiet {
            addPathAnnotations(path, best, focus: focus)
        }
        lastPathStart = start
        lastPathEnd = best.end
        if path.nestBan {
            var banned = nestBans[path] ?? []
            for node in best.nodes.dropFirst() { banned.insert(ObjectIdentifier(node)) }
            nestBans[path] = banned
        }
        return path.lastPosition ? .position(PositionRef(best.end)) : .number(best.count)
    }

    private func complete(_ search: Search, _ end: PositionNode, _ count: Int, _ nodes: [PositionNode]) throws(CQLError) {
        var score: Value?
        if let maximize = search.path.maximize {
            pathStack[pathStack.count - 1].count = count
            guard let value = try at(end, { () throws(CQLError) -> Value? in try evaluate(maximize) }) else { return }
            score = value
        }
        let candidate = Search.Candidate(end: end, count: count, nodes: nodes,
                                         comments: Array(comments[search.commentMark...]),
                                         atomics: atomicSnapshot(), score: score)
        if let current = search.best.first {
            let order = score.map { Self.compare($0, current.score ?? $0) } ?? (count < current.count ? -1 : count == current.count ? 0 : 1)
            if order > 0 {
                search.best = [candidate]
            } else if order == 0, search.path.keepAllBest {
                search.best.append(candidate)
            }
        } else {
            search.best = [candidate]
        }
        if search.path.firstMatch { search.stop = true }
    }

    private func matchSequence(_ items: ArraySlice<PathConstituent>, _ search: Search, _ node: PositionNode, _ count: Int,
                               _ nodes: [PositionNode], _ scope: DashScope?, _ next: Continuation) throws(CQLError) {
        guard !search.stop else { return }
        guard let first = items.first else {
            try next(node, count, nodes, scope)
            return
        }
        let rest = items.dropFirst()
        switch first {
        case .filter(let filter):
            pathStack[pathStack.count - 1].count = count
            let mark = comments.count
            let atomics = atomicSnapshot()
            let matched = try at(node, barrier: false) { () throws(CQLError) -> Bool in
                dashScopes.append(scope)
                defer { dashScopes.removeLast() }
                return try matches(filter)
            }
            if matched { try matchSequence(rest, search, node, count, nodes, scope, next) }
            if comments.count > mark { comments.removeSubrange(mark...) }
            restoreAtomics(atomics)
        case .move(let dash):
            try matchMove(dash, search, node, nodes) { (child, trail, newScope) throws(CQLError) in
                try self.matchSequence(rest, search, child, count + 1, trail, newScope, next)
            }
        case .chain(let inner):
            try matchSequence(ArraySlice(inner + rest), search, node, count, nodes, scope, next)
        case .repetition(let group, let minimum, let maximum):
            try matchRepetition(group, minimum, maximum, 0, rest, search, node, count, nodes, scope, next)
        }
    }

    private func matchRepetition(_ group: [PathConstituent], _ minimum: Int, _ maximum: Int?, _ times: Int,
                                 _ rest: ArraySlice<PathConstituent>, _ search: Search, _ node: PositionNode, _ count: Int,
                                 _ nodes: [PositionNode], _ scope: DashScope?, _ next: Continuation) throws(CQLError) {
        // Greedy: try one more repetition first.
        if maximum.map({ times < $0 }) ?? true {
            try matchSequence(group[...], search, node, count, nodes, scope) { (end, newCount, trail, newScope) throws(CQLError) in
                guard end !== node else { return }  // every repetition must consume a move
                try self.matchRepetition(group, minimum, maximum, times + 1, rest, search, end, newCount, trail, newScope, next)
            }
        }
        if times >= minimum {
            try matchSequence(rest, search, node, count, nodes, scope, next)
        }
    }

    /// Matches one ―― constituent from `node`, skipping out-of-focus moves.
    private func matchMove(_ dash: DashFilter, _ search: Search, _ node: PositionNode, _ trail: [PositionNode],
                           _ next: (PositionNode, [PositionNode], DashScope) throws(CQLError) -> Void) throws(CQLError) {
        guard !search.stop else { return }
        let candidates = search.path.primary ? Array(children(of: node).prefix(1)) : children(of: node)
        guard !candidates.isEmpty else { return }
        let (left, right) = try at(node, barrier: false) { () throws(CQLError) -> (SquareSet, SquareSet) in
            (try dash.left.map { (f) throws(CQLError) -> SquareSet in try evaluateSet(f) } ?? .all,
             try dash.right.map { (f) throws(CQLError) -> SquareSet in try evaluateSet(f) } ?? .all)
        }
        guard let promotion = try promotionTypes(dash, at: node) else { return }
        let scope = DashScope(left: left, right: right, focus: search.focus)
        for child in candidates {
            guard let move = child.move, !search.stop else { continue }
            if isInFocus(move, head: node, search) {
                if movedSquares(dash, move, left: left, right: right, promotion: promotion) != nil {
                    try next(child, trail + [child], scope)
                }
            } else if node !== search.start {
                try matchMove(dash, search, child, trail + [child], next)
            }
        }
    }

    private func isInFocus(_ move: MoveInfo, head: PositionNode, _ search: Search) -> Bool {
        guard let focus = search.focus else { return true }
        if let id = head.pieceID(at: move.from), focus.contains(id) { return true }
        if let rook = move.castlingRook, let id = head.pieceID(at: rook.from), focus.contains(id) { return true }
        if search.path.focusCapture, let square = move.captureSquare, let id = head.pieceID(at: square), focus.contains(id) {
            return true
        }
        return false
    }

    // MARK: - Atomic variables

    func atomicSnapshot() -> [String: Value] {
        var snapshot: [String: Value] = [:]
        for name in atomicVariables { snapshot[name] = variables[name] }
        return snapshot
    }

    func restoreAtomics(_ snapshot: [String: Value]) {
        for name in atomicVariables { variables[name] = snapshot[name] }
    }

    // MARK: - Annotations

    private func addPathAnnotations(_ path: PathFilter, _ best: Search.Candidate, focus: Set<Int>?) {
        let start = best.nodes[0]
        func add(_ text: String, at node: PositionNode) {
            comments.append(GeneratedComment(positionID: node.id, path: node.path, text: text))
        }
        let prefix = path.title.map { "\($0): " } ?? ""
        if path.piecePath, let focus {
            for id in focus.sorted() {
                var squares: [Int] = []
                for node in best.nodes {
                    guard let square = node.square(ofPiece: id) else { break }
                    if squares.last != square { squares.append(square) }
                }
                guard squares.count > 1, let piece = start.board.piece(at: squares[0]) else { continue }
                let route = squares.map(SquareName.name(of:)).joined(separator: "-")
                add("\(prefix)\(piece.asciiLetter)\(route)", at: start)
            }
        } else if let title = path.title {
            add(title, at: start)
        }
        if path.verbose {
            let total = best.count
            var index = 0
            for node in best.nodes.dropFirst() {
                guard let move = node.move, let parent = node.parent,
                      focus == nil || isFocused(move, head: parent, focus!, capture: path.focusCapture) else { continue }
                index += 1
                add("\(path.title ?? "⊢") \(index)/\(total)", at: node)
            }
        }
    }

    private func isFocused(_ move: MoveInfo, head: PositionNode, _ focus: Set<Int>, capture: Bool) -> Bool {
        if let id = head.pieceID(at: move.from), focus.contains(id) { return true }
        if let rook = move.castlingRook, let id = head.pieceID(at: rook.from), focus.contains(id) { return true }
        if capture, let square = move.captureSquare, let id = head.pieceID(at: square), focus.contains(id) { return true }
        return false
    }

    // MARK: - Path status filters

    func evaluatePathStatus(_ name: String) -> Value? {
        let state = pathStack.last
        switch name {
        case "pathstart":
            return (state?.start ?? lastPathStart).map { .position(PositionRef($0)) }
        case "pathlastposition":
            return lastPathEnd.map { .position(PositionRef($0)) }
        case "pathcount":
            return state.map { .number($0.count) }
        default:  // pathcountunfocused
            guard let state else { return nil }
            return .number(current.ply - state.start.ply - state.count)
        }
    }
}
