/// Conditions a game must meet for a CQL program to match it, extracted
/// statically from the program so that an external index can pre-filter
/// candidate games before running CQL on them.
///
/// The conditions are *necessary*: a game that fails any of them cannot
/// match. They are also *sufficient* when ``isExact`` is true; then the
/// index alone gives the same games as running the program.
public struct NecessaryConditions: Hashable, Sendable {
    /// Conditions on the game's tags. All must hold.
    public var game = GameConditions()
    /// Conditions that must all hold at one and the same position of the game.
    public var position = PositionConditions()
    /// Whether the conditions are equivalent to the program: a game matches
    /// the program exactly when some position satisfies ``position`` and the
    /// game satisfies ``game``.
    public var isExact = true
    /// Whether positions in variations can match (`variations` in the header).
    public var searchesVariations = false
    /// Descriptions of the parts of the program that were not translated.
    public var untranslated: [String] = []

    public init() {}
}

/// Conditions on PGN tags.
public struct GameConditions: Hashable, Sendable {
    /// Substring that must occur in a tag (CQL's implicit search: `player "Tal"`).
    public struct TagSubstring: Hashable, Sendable {
        /// Tag names, any of which may contain the text (`["White", "Black"]` for `player`).
        public var tags: [String]
        public var text: String
    }

    /// Allowed Elo values; `side` nil means the higher of the two Elos (`elo` alone).
    public struct EloRange: Hashable, Sendable {
        public var side: CQLColor?
        public var range: ClosedRange<Int>
    }

    public var substrings: [TagSubstring] = []
    public var elo: [EloRange] = []
    /// Allowed years (from the `Date` tag).
    public var year: ClosedRange<Int>?
    /// Required `Result` tag: `"1-0"`, `"0-1"` or `"1/2-1/2"`.
    public var result: String?
    /// Allowed game numbers (position in the input).
    public var gameNumber: ClosedRange<Int>?

    public init() {}

    public var isEmpty: Bool {
        substrings.isEmpty && elo.isEmpty && year == nil && result == nil && gameNumber == nil
    }
}

/// Conditions on one position.
public struct PositionConditions: Hashable, Sendable {
    /// The number of squares holding one of `pieces` within `squares` must lie
    /// in `count`. A plain piece designator gives `1...64`; `not` gives `0...0`.
    public struct PieceCount: Hashable, Sendable {
        public var pieces: PieceTypeSet
        public var squares: SquareSet
        public var count: ClosedRange<Int>

        /// The squares to check for each coloured piece type (empty squares,
        /// if included, are in ``includesEmptySquares``).
        public var squaresByPiece: [CQLPiece: SquareSet] {
            var result: [CQLPiece: SquareSet] = [:]
            for piece in pieces.pieces { result[piece] = squares }
            return result
        }

        public var includesEmptySquares: Bool { pieces.contains(.empty) }
    }

    public var pieces: [PieceCount] = []
    /// Required side to move.
    public var sideToMove: CQLColor?
    /// Board placements from `fen "…"` filters, with CQL's wildcards (`A`, `a`, `_`, `.`).
    public var placements: [String] = []

    public init() {}

    public var isEmpty: Bool { pieces.isEmpty && sideToMove == nil && placements.isEmpty }
}

/// Static analysis of CQL programs.
public enum CQLPlan {
    /// The conditions a game must meet to match `program`.
    public static func necessaryConditions(of program: CQLProgram) -> NecessaryConditions {
        var conditions = NecessaryConditions()
        let header = program.header
        conditions.searchesVariations = header.variations
        conditions.game.result = header.result
        conditions.game.gameNumber = header.gameNumber
        if let matchCount = header.matchCount {
            guard matchCount.lowerBound >= 1 else {
                // `matchcount 0 …` can match games where no position matches.
                conditions.isExact = false
                conditions.untranslated.append("matchcount \(matchCount.lowerBound) \(matchCount.upperBound)")
                return conditions
            }
            if matchCount != 1...Int.max {
                conditions.isExact = false
                conditions.untranslated.append("matchcount \(matchCount.lowerBound) \(matchCount.upperBound)")
            }
        }
        var planner = Planner(conditions: conditions)
        planner.conjunct(program.body)
        return planner.conditions
    }

    /// Walks the top-level conjunction of a program.
    private struct Planner {
        var conditions: NecessaryConditions

        mutating func untranslated(_ filter: Filter) {
            conditions.isExact = false
            conditions.untranslated.append(Self.describe(filter))
        }

        mutating func conjunct(_ filter: Filter) {
            switch filter {
            case .compound(let filters):
                for filter in filters { conjunct(filter) }
            case .binary(.and, let lhs, let rhs):
                conjunct(lhs)
                conjunct(rhs)
            case .pieceDesignator(let designator):
                addPieces(designator, 1...64)
            case .not(.pieceDesignator(let designator)):
                addPieces(designator, 0...0)
            case .keyword("wtm"):
                conditions.position.sideToMove = .white
            case .keyword("btm"):
                conditions.position.sideToMove = .black
            case .keyword("true"):
                break
            case .fenMatch(let placement):
                conditions.position.placements.append(placement)
            case .result(let text):
                conditions.game.result = text
            case .binary(.in, .string(let text), .tagValue(let field)):
                conditions.game.substrings.append(.init(tags: Self.tagNames(field), text: text))
            case .comment, .message:
                break  // always match; they only add output
            case .sort(_, _, _, let inner):
                conjunct(inner)  // sort matches when its argument does
            case .binary(let op, let lhs, let rhs) where op.isRelational && op != .notEqual:
                if !relational(op, lhs, rhs) { untranslated(filter) }
            default:
                untranslated(filter)
            }
        }

        mutating func addPieces(_ designator: PieceDesignator, _ count: ClosedRange<Int>) {
            conditions.position.pieces.append(.init(pieces: designator.pieceTypes, squares: designator.squares, count: count))
        }

        /// A quantity a relational operator can compare with a literal.
        enum Quantity {
            case pieces(PieceDesignator)
            case elo(CQLColor?)
            case year
        }

        static func quantity(_ filter: Filter) -> Quantity? {
            switch filter {
            case .pieceDesignator(let designator), .cardinality(.pieceDesignator(let designator)):
                return .pieces(designator)
            case .elo(let side):
                return .elo(side)
            case .keyword("year"):
                return .year
            default:
                return nil
            }
        }

        /// Translates `quantity op literal`, `literal op quantity` and chains
        /// such as `4 ≤ ♙ < 7`. Returns false if the comparison has another shape.
        mutating func relational(_ op: BinaryOperator, _ lhs: Filter, _ rhs: Filter) -> Bool {
            // Right-associative chain: the value of `rhs` is its left operand.
            if case .binary(let innerOp, let innerLeft, let innerRight) = rhs, innerOp.isRelational, innerOp != .notEqual {
                guard relational(innerOp, innerLeft, innerRight) else { return false }
                return relational(op, lhs, innerLeft)
            }
            if let quantity = Self.quantity(lhs), case .number(let value) = rhs {
                return constrain(quantity, Self.range(op, value))
            }
            if case .number(let value) = lhs, let quantity = Self.quantity(rhs) {
                return constrain(quantity, Self.range(Self.mirrored(op), value))
            }
            return false
        }

        mutating func constrain(_ quantity: Quantity, _ range: ClosedRange<Int>?) -> Bool {
            guard let range else { return false }
            switch quantity {
            case .pieces(let designator):
                addPieces(designator, range.clamped(to: 0...64))
            case .elo(let side):
                conditions.game.elo.append(.init(side: side, range: range))
            case .year:
                conditions.game.year = conditions.game.year.map { $0.clamped(to: range) } ?? range
            }
            return true
        }

        /// The values `x` with `x op value`.
        static func range(_ op: BinaryOperator, _ value: Int) -> ClosedRange<Int>? {
            switch op {
            case .equal: return value...value
            case .less: return value > Int.min ? Int.min...(value - 1) : nil
            case .lessEqual: return Int.min...value
            case .greater: return value < Int.max ? (value + 1)...Int.max : nil
            case .greaterEqual: return value...Int.max
            default: return nil
            }
        }

        /// `literal op x` ≡ `x mirrored(op) literal`.
        static func mirrored(_ op: BinaryOperator) -> BinaryOperator {
            switch op {
            case .less: .greater
            case .lessEqual: .greaterEqual
            case .greater: .less
            case .greaterEqual: .lessEqual
            default: op
            }
        }

        static func tagNames(_ field: TagField) -> [String] {
            switch field {
            case .player(nil): ["White", "Black"]
            case .player(.white?): ["White"]
            case .player(.black?): ["Black"]
            case .event: ["Event"]
            case .site: ["Site"]
            case .date: ["Date"]
            case .eventdate: ["EventDate"]
            case .eco: ["ECO"]
            case .tag(let name): [name]
            }
        }

        static func describe(_ filter: Filter) -> String {
            let text = String(describing: filter)
            return text.count > 120 ? String(text.prefix(117)) + "…" : text
        }
    }
}

extension CQLProgram {
    /// The conditions a game must meet to match this program. See ``CQLPlan``.
    public var necessaryConditions: NecessaryConditions { CQLPlan.necessaryConditions(of: self) }
}
