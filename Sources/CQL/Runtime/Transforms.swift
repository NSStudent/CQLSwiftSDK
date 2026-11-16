/// A basic board transform: an element of the dihedral group D4 (optionally
/// combined with a colour inversion) or a translation.
struct BoardTransform: Hashable, Sendable {
    var name: String
    /// Swap file and rank before flipping.
    var swap = false
    var flipFile = false
    var flipRank = false
    var invertColor = false
    var shiftFiles = 0
    var shiftRanks = 0

    var isIdentity: Bool {
        !swap && !flipFile && !flipRank && !invertColor && shiftFiles == 0 && shiftRanks == 0
    }

    static let identity = BoardTransform(name: "<>")

    static let d4: [BoardTransform] = [
        .identity,
        BoardTransform(name: "<rotate90>", swap: true, flipFile: true),
        BoardTransform(name: "<rotate180>", flipFile: true, flipRank: true),
        BoardTransform(name: "<rotate270>", swap: true, flipRank: true),
        BoardTransform(name: "<reflect_h>", flipRank: true),
        BoardTransform(name: "<reflect_v>", flipFile: true),
        BoardTransform(name: "<reflect_a1h8>", swap: true),
        BoardTransform(name: "<reflect_h1a8>", swap: true, flipFile: true, flipRank: true),
    ]

    static let colorFlip = BoardTransform(name: "<flipcolor>", flipRank: true, invertColor: true)

    static func group(_ kind: TransformKind) throws(CQLError) -> [BoardTransform] {
        switch kind {
        case .flip: return d4
        case .flipcolor: return [.identity, colorFlip]
        case .reversecolor: return [colorFlip]
        case .fliphorizontal: return [.identity, d4[4]]
        case .flipvertical: return [.identity, d4[5]]
        case .rotate90: return Array(d4[0...3])
        case .shift:
            var result: [BoardTransform] = []
            for files in -7...7 {
                for ranks in -7...7 {
                    result.append(BoardTransform(name: "<shift \(files) \(ranks)>", shiftFiles: files, shiftRanks: ranks))
                }
            }
            return result
        case .shifthorizontal:
            return (-7...7).map { BoardTransform(name: "<shift \($0) 0>", shiftFiles: $0) }
        case .shiftvertical:
            return (-7...7).map { BoardTransform(name: "<shift 0 \($0)>", shiftRanks: $0) }
        case .rotate45:
            throw CQLError(.semantic, "rotate45 is not supported yet by this implementation")
        }
    }

    // MARK: - Squares

    func mapSquare(_ square: Int) -> Int {
        var file = square % 8, rank = square / 8
        if swap { (file, rank) = (rank, file) }
        if flipFile { file = 7 - file }
        if flipRank { rank = 7 - rank }
        return rank * 8 + file
    }

    /// Maps a designator's square set; `nil` when it becomes empty.
    func mapSquares(_ squares: SquareSet) -> SquareSet? {
        if squares == .all || squares.isEmpty { return squares }
        var result: SquareSet
        if shiftFiles != 0 || shiftRanks != 0 {
            result = squares
            for _ in 0..<abs(shiftFiles) { result = Self.unitShift(result, horizontal: true, positive: shiftFiles > 0) }
            for _ in 0..<abs(shiftRanks) { result = Self.unitShift(result, horizontal: false, positive: shiftRanks > 0) }
        } else {
            result = SquareSet(indices: squares.map(mapSquare))
        }
        return result.isEmpty ? nil : result
    }

    /// One translation step; complete files (vertical shift) or complete
    /// ranks (horizontal shift) are left in place, squares leaving the board are dropped.
    static func unitShift(_ squares: SquareSet, horizontal: Bool, positive: Bool) -> SquareSet {
        var invariant = SquareSet()
        for line in 0..<8 {
            let full = horizontal ? SquareSet.rank(line) : SquareSet.file(line)
            if full.isSubset(of: squares) { invariant |= full }
        }
        var result = invariant
        let direction: BoardDirection = horizontal ? (positive ? .right : .left) : (positive ? .up : .down)
        for square in squares {
            if let next = Attacks.step(square, direction) { result.insert(next) }
        }
        return result
    }

    /// Whether light squares map to dark squares.
    var swapsSquareColors: Bool {
        if shiftFiles != 0 || shiftRanks != 0 { return (shiftFiles + shiftRanks) % 2 != 0 }
        return (mapSquare(0) % 8 + mapSquare(0) / 8) % 2 != 0
    }

    // MARK: - Directions

    func mapDirection(_ direction: BoardDirection) -> BoardDirection {
        guard shiftFiles == 0, shiftRanks == 0 else { return direction }
        var (df, dr) = direction.delta
        if swap { (df, dr) = (dr, df) }
        if flipFile { df = -df }
        if flipRank { dr = -dr }
        return BoardDirection.allCases.first { $0.delta == (df, dr) }!
    }

    func mapDirectionName(_ name: String) -> String {
        if let basic = BoardDirection(name: name) { return mapDirection(basic).name }
        if swap, name == "vertical" { return "horizontal" }
        if swap, name == "horizontal" { return "vertical" }
        return name
    }

    // MARK: - Filters

    /// Rewrites `filter` under this transform; `nil` if the result is invalid
    /// (a square designator became empty).
    func apply(to filter: Filter) -> Filter? {
        if isIdentity { return filter }
        return try? rewrite(filter)
    }

    private struct Invalid: Error {}

    private func rewrite(_ filter: Filter) throws(CQLError) -> Filter {
        switch filter {
        case .notransform, .variable:
            return filter
        case .pieceDesignator(var designator):
            if invertColor { designator.pieceTypes = designator.pieceTypes.colorReversed }
            guard let squares = mapSquares(designator.squares) else {
                throw CQLError(.semantic, "invalid transformed designator")
            }
            designator.squares = squares
            return .pieceDesignator(designator)
        case .keyword(let name):
            if name == "currenttransform" { return .string(self.name) }
            guard invertColor else { return filter }
            switch name {
            case "wtm": return .keyword("btm")
            case "btm": return .keyword("wtm")
            case "white": return .keyword("black")
            case "black": return .keyword("white")
            default: return filter
            }
        case .tagValue(.player(let color?)) where invertColor:
            return .tagValue(.player(color.opposite))
        case .elo(let color?) where invertColor:
            return .elo(color.opposite)
        case .result(let text) where invertColor:
            return .result(text == "1-0" ? "0-1" : text == "0-1" ? "1-0" : text)
        case .direction(let name, let range, let argument):
            return .direction(mapDirectionName(name), range: range, try rewrite(argument))
        case .ray(let direction, let sets, let xray):
            var mapped: [Filter] = []
            for set in sets { mapped.append(try rewrite(set)) }
            return .ray(direction: direction.map(mapDirectionName), mapped, xray: xray)
        case .prefix(let name, let argument) where (name == "light" || name == "dark") && swapsSquareColors:
            return .prefix(name == "light" ? "dark" : "light", try rewrite(argument))
        default:
            return try filter.mapChildren { (child) throws(CQLError) -> Filter in try rewrite(child) }
        }
    }
}

extension BoardDirection {
    init?(name: String) {
        switch name {
        case "up": self = .up
        case "down": self = .down
        case "right": self = .right
        case "left": self = .left
        case "northeast": self = .northeast
        case "northwest": self = .northwest
        case "southeast": self = .southeast
        case "southwest": self = .southwest
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .up: "up"
        case .down: "down"
        case .right: "right"
        case .left: "left"
        case .northeast: "northeast"
        case .northwest: "northwest"
        case .southeast: "southeast"
        case .southwest: "southwest"
        }
    }

    /// The basic directions denoted by a direction keyword.
    static func named(_ name: String) -> [BoardDirection]? {
        if let basic = BoardDirection(name: name) { return [basic] }
        switch name {
        case "vertical": return [.up, .down]
        case "horizontal": return [.left, .right]
        case "orthogonal": return orthogonal
        case "diagonal": return diagonal
        case "anydirection": return allCases
        default: return nil
        }
    }
}

extension Filter {
    /// Replaces every transform filter by its orbit of rewritten filters.
    func resolvingTransforms() throws(CQLError) -> Filter {
        if case .notransform(let inner) = self {
            return .notransform(try inner.resolvingTransforms())
        }
        let resolved = try mapChildren { (child) throws(CQLError) -> Filter in try child.resolvingTransforms() }
        guard case .transform(let kind, let count, let argument) = resolved else { return resolved }
        var orbit: [Filter] = []
        var seen: Set<Filter> = []
        for transform in try BoardTransform.group(kind) {
            guard let element = transform.apply(to: argument), seen.insert(element).inserted else { continue }
            orbit.append(element)
        }
        return .transformOrbit(orbit, count: count)
    }
}
