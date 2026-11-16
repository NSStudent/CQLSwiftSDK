/// A compass direction on the chessboard, from White's point of view.
public enum BoardDirection: Int, Sendable, CaseIterable, Hashable {
    case up, down, right, left, northeast, northwest, southeast, southwest

    public var delta: (file: Int, rank: Int) {
        switch self {
        case .up: (0, 1)
        case .down: (0, -1)
        case .right: (1, 0)
        case .left: (-1, 0)
        case .northeast: (1, 1)
        case .northwest: (-1, 1)
        case .southeast: (1, -1)
        case .southwest: (-1, -1)
        }
    }

    public static let orthogonal: [BoardDirection] = [.up, .down, .right, .left]
    public static let diagonal: [BoardDirection] = [.northeast, .northwest, .southeast, .southwest]

    public var isOrthogonal: Bool { rawValue < 4 }
    public var isDiagonal: Bool { rawValue >= 4 }
}

/// Precomputed attack helpers. Square indices use `rank * 8 + file`.
public enum Attacks {
    @inline(__always)
    static func step(_ square: Int, _ direction: BoardDirection) -> Int? {
        let (df, dr) = direction.delta
        let file = square % 8 + df
        let rank = square / 8 + dr
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        return rank * 8 + file
    }

    static let knightTable: [SquareSet] = (0..<64).map { square in
        var result = SquareSet()
        let file = square % 8, rank = square / 8
        for (df, dr) in [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)] {
            let f = file + df, r = rank + dr
            if (0..<8).contains(f), (0..<8).contains(r) { result.insert(r * 8 + f) }
        }
        return result
    }

    static let kingTable: [SquareSet] = (0..<64).map { square in
        var result = SquareSet()
        for direction in BoardDirection.allCases {
            if let next = step(square, direction) { result.insert(next) }
        }
        return result
    }

    static let pawnAttackTable: [[SquareSet]] = [CQLColor.white, .black].map { color in
        (0..<64).map { square in
            var result = SquareSet()
            let directions: [BoardDirection] = color == .white ? [.northeast, .northwest] : [.southeast, .southwest]
            for direction in directions {
                if let next = step(square, direction) { result.insert(next) }
            }
            return result
        }
    }

    /// Squares reached by sliding from `square` in `direction` until (and
    /// including) the first occupied square.
    public static func ray(from square: Int, _ direction: BoardDirection, occupied: SquareSet) -> SquareSet {
        var result = SquareSet()
        var current = square
        while let next = step(current, direction) {
            result.insert(next)
            if occupied.contains(next) { break }
            current = next
        }
        return result
    }

    /// All squares from `square` (exclusive) to the edge in `direction`.
    public static func fullRay(from square: Int, _ direction: BoardDirection) -> SquareSet {
        ray(from: square, direction, occupied: .empty)
    }

    /// Squares attacked by `piece` standing on `square`.
    public static func attacks(of piece: CQLPiece, from square: Int, occupied: SquareSet) -> SquareSet {
        switch piece.kind {
        case .pawn: return pawnAttackTable[piece.color.rawValue][square]
        case .knight: return knightTable[square]
        case .king: return kingTable[square]
        case .bishop: return sliding(from: square, BoardDirection.diagonal, occupied: occupied)
        case .rook: return sliding(from: square, BoardDirection.orthogonal, occupied: occupied)
        case .queen: return sliding(from: square, BoardDirection.allCases, occupied: occupied)
        }
    }

    static func sliding(from square: Int, _ directions: [BoardDirection], occupied: SquareSet) -> SquareSet {
        var result = SquareSet()
        for direction in directions { result |= ray(from: square, direction, occupied: occupied) }
        return result
    }

    /// The squares strictly between two squares on a common line, or empty.
    public static func between(_ a: Int, _ b: Int) -> SquareSet {
        guard let direction = direction(from: a, to: b) else { return .empty }
        var result = SquareSet()
        var current = a
        while let next = step(current, direction), next != b {
            result.insert(next)
            current = next
        }
        return result
    }

    /// The direction from `a` to `b` if both lie on a common rank, file or diagonal.
    public static func direction(from a: Int, to b: Int) -> BoardDirection? {
        guard a != b else { return nil }
        let df = b % 8 - a % 8, dr = b / 8 - a / 8
        guard df == 0 || dr == 0 || abs(df) == abs(dr) else { return nil }
        let delta = (df.signum(), dr.signum())
        return BoardDirection.allCases.first { $0.delta == delta }
    }
}

/// A chess position's piece placement and state, optimised for CQL queries.
public struct BoardState: Hashable, Sendable {
    /// One set per piece, indexed by `color * 6 + kind`.
    public var pieceSets: [SquareSet]
    public var sideToMove: CQLColor
    public var castling: CastlingSet
    public var enPassantTarget: Int?

    public struct CastlingSet: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let whiteKingside = CastlingSet(rawValue: 1)
        public static let whiteQueenside = CastlingSet(rawValue: 2)
        public static let blackKingside = CastlingSet(rawValue: 4)
        public static let blackQueenside = CastlingSet(rawValue: 8)
    }

    public init(pieceSets: [SquareSet] = Array(repeating: .empty, count: 12),
                sideToMove: CQLColor = .white,
                castling: CastlingSet = [],
                enPassantTarget: Int? = nil) {
        self.pieceSets = pieceSets
        self.sideToMove = sideToMove
        self.castling = castling
        self.enPassantTarget = enPassantTarget
    }

    public func squares(of piece: CQLPiece) -> SquareSet { pieceSets[piece.bit] }

    public func squares(ofColor color: CQLColor) -> SquareSet {
        var result = SquareSet()
        for kind in 0..<6 { result |= pieceSets[color.rawValue * 6 + kind] }
        return result
    }

    public var occupied: SquareSet { squares(ofColor: .white) | squares(ofColor: .black) }

    public func piece(at square: Int) -> CQLPiece? {
        for bit in 0..<12 where pieceSets[bit].contains(square) {
            return CQLPiece(CQLPieceKind(rawValue: bit % 6)!, CQLColor(rawValue: bit / 6)!)
        }
        return nil
    }

    /// The squares denoted by a set of piece types.
    public func squares(of types: PieceTypeSet) -> SquareSet {
        var result = SquareSet()
        for bit in 0..<12 where types.rawValue & (1 << UInt16(bit)) != 0 {
            result |= pieceSets[bit]
        }
        if types.contains(.empty) { result |= ~occupied }
        return result
    }

    public func evaluate(_ designator: PieceDesignator) -> SquareSet {
        squares(of: designator.pieceTypes) & designator.squares
    }

    public func kingSquare(_ color: CQLColor) -> Int? { squares(of: CQLPiece(.king, color)).first }

    /// Squares attacked by the piece on `square` (empty if the square is empty).
    public func attacks(from square: Int) -> SquareSet {
        guard let piece = piece(at: square) else { return .empty }
        return Attacks.attacks(of: piece, from: square, occupied: occupied)
    }

    /// Pieces (of any colour) that attack `square`.
    public func attackers(of square: Int) -> SquareSet {
        let occupied = self.occupied
        var result = SquareSet()
        for from in occupied where Attacks.attacks(of: piece(at: from)!, from: from, occupied: occupied).contains(square) {
            result.insert(from)
        }
        return result
    }

    public func isAttacked(_ square: Int, by color: CQLColor) -> Bool {
        !(attackers(of: square) & squares(ofColor: color)).isEmpty
    }

    public func isInCheck(_ color: CQLColor) -> Bool {
        guard let king = kingSquare(color) else { return false }
        return isAttacked(king, by: color.opposite)
    }

    /// Pieces of `color` that are pinned against their own king by an
    /// opposing slider.
    public func pinned(_ color: CQLColor) -> SquareSet {
        guard let king = kingSquare(color) else { return .empty }
        var result = SquareSet()
        let occupied = self.occupied
        let own = squares(ofColor: color)
        let enemy = color.opposite
        for direction in BoardDirection.allCases {
            let sliders = direction.isOrthogonal
                ? squares(of: CQLPiece(.rook, enemy)) | squares(of: CQLPiece(.queen, enemy))
                : squares(of: CQLPiece(.bishop, enemy)) | squares(of: CQLPiece(.queen, enemy))
            var current = king
            var candidate: Int?
            while let next = Attacks.step(current, direction) {
                current = next
                guard occupied.contains(next) else { continue }
                if candidate == nil {
                    guard own.contains(next) else { break }
                    candidate = next
                } else {
                    if sliders.contains(next) { result.insert(candidate!) }
                    break
                }
            }
        }
        return result
    }
}
