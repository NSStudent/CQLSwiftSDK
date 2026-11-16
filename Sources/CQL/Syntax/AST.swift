/// A parsed CQL file.
public struct CQLProgram: Hashable, Sendable {
    public var header: CQLHeader
    /// The body: an implicit compound filter.
    public var body: Filter
    /// User-defined functions by name.
    public var functions: [String: FunctionDefinition]

    public init(header: CQLHeader, body: Filter, functions: [String: FunctionDefinition] = [:]) {
        self.header = header
        self.body = body
        self.functions = functions
    }
}

/// `function name(params) { body }`
public struct FunctionDefinition: Hashable, Sendable {
    public var name: String
    public var parameters: [String]
    public var body: Filter
}

/// Binary operators.
public enum BinaryOperator: String, Hashable, Sendable {
    case add = "+", subtract = "-", multiply = "*", divide = "/", modulo = "%"
    case union = "|", intersection = "&"
    case equal = "==", notEqual = "!=", less = "<", lessEqual = "<=", greater = ">", greaterEqual = ">="
    case precedes = "≺", succeeds = "≻", precedesOrEqual = "≼", succeedsOrEqual = "≽"
    case regexMatch = "~~"
    case `in` = "in"
    case and, or

    public var isRelational: Bool {
        switch self {
        case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual: true
        default: false
        }
    }

    public var isArithmetic: Bool {
        switch self {
        case .add, .subtract, .multiply, .divide, .modulo: true
        default: false
        }
    }
}

/// Assignment operators.
public enum AssignmentOperator: String, Hashable, Sendable {
    case assign = "=", assignIfNonEmpty = "=?"
    case add = "+=", subtract = "-=", multiply = "*=", divide = "/=", modulo = "%="
}

/// The 6.2 move filter `L――R=P(targets)` / `L×R`.
public struct DashFilter: Hashable, Sendable {
    public var left: Filter?
    public var right: Filter?
    public var isCapture: Bool
    /// Promotion piece types (`=♖♗`), colour ignored. `nil` = no promotion constraint.
    public var promotion: PieceTypeSet?
    /// `=T` where `T` is a string filter of type letters ("RBN").
    public var promotionFilter: Filter?
    public var targets: [Filter]?

    public init(left: Filter? = nil, right: Filter? = nil, isCapture: Bool = false,
                promotion: PieceTypeSet? = nil, targets: [Filter]? = nil) {
        self.left = left
        self.right = right
        self.isCapture = isCapture
        self.promotion = promotion
        self.targets = targets
    }
}

/// Which moves a dash-based filter looks at.
public enum MoveSource: String, Hashable, Sendable {
    /// Moves present in the PGN from the current position.
    case game
    /// The move that led to the current position (`currentmove`).
    case current
    case legal
    case pseudolegal
}

/// `find` search modes.
public enum FindMode: Hashable, Sendable {
    case first
    case all
    case range(ClosedRange<Int>)
}

/// A transform filter kind.
public enum TransformKind: String, Hashable, Sendable, CaseIterable {
    case flip, flipcolor, reversecolor, fliphorizontal, flipvertical
    case rotate90, rotate45, shift, shifthorizontal, shiftvertical
}

/// Tag-based string filters.
public enum TagField: Hashable, Sendable {
    case player(CQLColor?)
    case event, site, date, eventdate, eco
    case tag(String)
}

/// One element of a `⊢` filter body.
public indirect enum PathConstituent: Hashable, Sendable {
    /// A ―― or × constituent (matched against one move).
    case move(DashFilter)
    /// A filter constituent (matched against the current position).
    case filter(Filter)
    /// `( … )`
    case chain([PathConstituent])
    /// `C*`, `C+`, `C?`, `C{m,n}` (`maximum == nil` means unbounded).
    case repetition([PathConstituent], minimum: Int, maximum: Int?)
}

/// `⊢ parameters constituents` (also written `path`).
public struct PathFilter: Hashable, Sendable {
    public var primary = false
    public var focus: Filter?
    public var focusCapture = false
    public var maximize: Filter?
    public var verbose = false
    public var keepAllBest = false
    public var title: String?
    public var piecePath = false
    public var quiet = false
    public var nestBan = false
    public var firstMatch = false
    public var lastPosition = false
    public var constituents: [PathConstituent] = []

    public init() {}
}

/// A CQL filter (an AST node).
public indirect enum Filter: Hashable, Sendable {
    // Literals and references
    case number(Int)
    case string(String)
    case pieceDesignator(PieceDesignator)
    case variable(String)
    /// A filter without arguments: `check`, `mate`, `wtm`, `ply`, `from`, `true`, …
    case keyword(String)
    /// `{ f1 f2 … }` (also the implicit top-level body).
    case compound([Filter])
    case captureGroup(Int)
    case captureGroupIndex(Int)

    // Operators
    case not(Filter)
    case negate(Filter)            // unary -
    case complement(Filter)        // ~
    case cardinality(Filter)       // #
    case binary(BinaryOperator, Filter, Filter)
    /// `x1 → x2 → … → xn` (or `←` chains when `reversed`).
    case attackChain([Filter], reversed: Bool)
    /// `position : filter`
    case at(Filter, Filter)
    /// `x[i]` or `x[i:j]` (slice when `isSlice`; missing bounds are `nil`).
    case `subscript`(Filter, Filter?, Filter?, isSlice: Bool)

    /// A named filter with one argument: `rank x`, `abs n`, `power S`, `light S`, …
    case prefix(String, Filter)
    /// A named filter with a parenthesised argument list: `between(a b)`, `max(…)`, …
    case call(String, [Filter])
    /// Direction filters: `up 2 3 S`, `orthogonal S`, …
    case direction(String, range: ClosedRange<Int>?, Filter)
    /// `ray [direction] (s1 s2 …)` / `xray (…)`
    case ray(direction: String?, [Filter], xray: Bool)
    /// `pin [from S] [through S] [to S]`; `role` is the first parameter written.
    case pin(from: Filter?, through: Filter?, to: Filter?, role: String)

    // Variables and control flow
    case assign(String, AssignmentOperator, Filter)
    case pieceAssign(String, Filter)
    case subscriptAssign(String, key: Filter, end: Filter?, isSlice: Bool, value: Filter)
    case persistent(quiet: Bool, String, AssignmentOperator, Filter)
    /// `atomic x = F`: an assignment whose variable is rolled back when ⊢ backtracks.
    case atomic(String, AssignmentOperator, Filter)
    case unbind(String, key: Filter?)
    case isBound(String, negated: Bool)
    /// `square [all] x in S body`, `piece [all] x in S body`, `x∊S body`, `∀x∊S body`.
    case iterate(isPiece: Bool, all: Bool, variable: String, domain: Filter, body: Filter)
    /// `K∊D body`
    case iterateDictionary(variable: String, dictionary: String, body: Filter)
    case ifThen(Filter, Filter, Filter?)
    case loop(Filter)
    case whileLoop(Filter, Filter)
    case whileRegex(target: Filter, pattern: String, body: Filter)
    case functionCall(String, [Filter])
    case dictionaryDeclaration(name: String, local: Bool)
    case assert(Filter)

    // Game data
    case tagValue(TagField)
    case elo(CQLColor?)
    case result(String)
    case fenMatch(String)
    case originalComment(String?)

    // Game tree and moves
    case dash(DashFilter, source: MoveSource)
    case countMoves(DashFilter, source: MoveSource)
    case find(quiet: Bool, mode: FindMode, backward: Bool, Filter)
    case echo(source: String, target: String, includeSelf: Bool, quiet: Bool, Filter)
    case path(PathFilter)
    /// `consecutivemoves [quiet] [range] (x y)`
    case consecutiveMoves(quiet: Bool, range: ClosedRange<Int>?, Filter, Filter)
    case child(Filter?)
    case position(Filter)

    // Transforms
    case transform(TransformKind, count: Bool, Filter)
    /// A transform resolved into the (de-duplicated) list of transformed filters.
    case transformOrbit([Filter], count: Bool)
    case notransform(Filter)

    // Output
    case comment([Filter])
    case message(quiet: Bool, [Filter])
    case sort(min: Bool, quiet: Bool, documentation: String?, Filter)
    case setTag(Filter, Filter)
}
