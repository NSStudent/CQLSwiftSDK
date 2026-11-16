/// The colour of a chess piece in CQL.
public enum CQLColor: Int, Sendable, Hashable {
    case white = 0
    case black = 1

    public var opposite: CQLColor { self == .white ? .black : .white }
}

/// The type of a chess piece in CQL.
public enum CQLPieceKind: Int, Sendable, Hashable, CaseIterable {
    case pawn = 0, knight, bishop, rook, queen, king

    public var asciiLetter: Character {
        switch self {
        case .pawn: "P"
        case .knight: "N"
        case .bishop: "B"
        case .rook: "R"
        case .queen: "Q"
        case .king: "K"
        }
    }

    /// Material value used by `power`.
    public var power: Int {
        switch self {
        case .pawn: 1
        case .knight, .bishop: 3
        case .rook: 5
        case .queen: 9
        case .king: 0
        }
    }
}

/// A coloured piece.
public struct CQLPiece: Hashable, Sendable {
    public var kind: CQLPieceKind
    public var color: CQLColor

    public init(_ kind: CQLPieceKind, _ color: CQLColor) {
        self.kind = kind
        self.color = color
    }

    public var asciiLetter: Character {
        color == .white ? kind.asciiLetter : Character(kind.asciiLetter.lowercased())
    }

    public var figurine: Character {
        let white: [Character] = ["♙", "♘", "♗", "♖", "♕", "♔"]
        let black: [Character] = ["♟", "♞", "♝", "♜", "♛", "♚"]
        return color == .white ? white[kind.rawValue] : black[kind.rawValue]
    }

    /// Bit used by ``PieceTypeSet``.
    var bit: Int { color.rawValue * 6 + kind.rawValue }
}

/// A set of piece types (including the "empty square" type) as used by piece
/// designators.
public struct PieceTypeSet: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public init(_ piece: CQLPiece) { self.rawValue = 1 << UInt16(piece.bit) }

    public static let empty = PieceTypeSet(rawValue: 1 << 12)
    public static let white = PieceTypeSet(rawValue: 0x3F)
    public static let black = PieceTypeSet(rawValue: 0x3F << 6)
    public static let anyPiece: PieceTypeSet = [.white, .black]
    public static let everything: PieceTypeSet = [.white, .black, .empty]

    public func contains(_ piece: CQLPiece) -> Bool { rawValue & (1 << UInt16(piece.bit)) != 0 }

    public var pieces: [CQLPiece] {
        var result: [CQLPiece] = []
        for color in [CQLColor.white, .black] {
            for kind in CQLPieceKind.allCases where contains(CQLPiece(kind, color)) {
                result.append(CQLPiece(kind, color))
            }
        }
        return result
    }

    /// Parses one ASCII or Unicode simple piece type designator character.
    public init?(character: Character) {
        switch character {
        case "K", "♔": self.init(CQLPiece(.king, .white))
        case "Q", "♕": self.init(CQLPiece(.queen, .white))
        case "R", "♖": self.init(CQLPiece(.rook, .white))
        case "B", "♗": self.init(CQLPiece(.bishop, .white))
        case "N", "♘": self.init(CQLPiece(.knight, .white))
        case "P", "♙": self.init(CQLPiece(.pawn, .white))
        case "k", "♚": self.init(CQLPiece(.king, .black))
        case "q", "♛": self.init(CQLPiece(.queen, .black))
        case "r", "♜": self.init(CQLPiece(.rook, .black))
        case "b", "♝": self.init(CQLPiece(.bishop, .black))
        case "n", "♞": self.init(CQLPiece(.knight, .black))
        case "p", "♟": self.init(CQLPiece(.pawn, .black))
        case "A", "△": self.init(rawValue: PieceTypeSet.white.rawValue)
        case "a", "▲": self.init(rawValue: PieceTypeSet.black.rawValue)
        case "_", "□": self.init(rawValue: PieceTypeSet.empty.rawValue)
        case "◭": self.init(rawValue: PieceTypeSet.anyPiece.rawValue)
        default: return nil
        }
    }

    public static func isUnicodePieceCharacter(_ character: Character) -> Bool {
        "♔♕♖♗♘♙♚♛♜♝♞♟△▲□◭".contains(character)
    }

    /// The colour-swapped piece types (used by colour-reversing transforms).
    public var colorReversed: PieceTypeSet {
        let white = rawValue & 0x3F
        let black = (rawValue >> 6) & 0x3F
        return PieceTypeSet(rawValue: (white << 6) | black | (rawValue & PieceTypeSet.empty.rawValue))
    }

    public var description: String {
        if self == .everything { return "" }
        if self == .white { return "A" }
        if self == .black { return "a" }
        if self == .empty { return "_" }
        if self == .anyPiece { return "[Aa]" }
        var text = pieces.map { String($0.asciiLetter) }.joined()
        if contains(.empty) { text += "_" }
        return text.count == 1 ? text : "[\(text)]"
    }
}

/// A piece designator such as `Ra1`, `[Qq]`, `♙♟d-e1-8`, `_f1-8` or `a-h3`.
public struct PieceDesignator: Hashable, Sendable, CustomStringConvertible {
    public var pieceTypes: PieceTypeSet
    public var squares: SquareSet

    public init(pieceTypes: PieceTypeSet = .everything, squares: SquareSet = .all) {
        self.pieceTypes = pieceTypes
        self.squares = squares
    }

    public var description: String {
        let squareText: String
        if squares == .all {
            squareText = pieceTypes == .everything ? "a-h1-8" : ""
        } else {
            squareText = squares.description
        }
        return pieceTypes.description + squareText
    }
}
