import FischerCore
import Foundation

/// Information about the move that led to a position.
public struct MoveInfo: Hashable, Sendable {
    public var from: Int
    public var to: Int
    public var piece: CQLPiece
    public var captured: CQLPiece?
    /// The square of the captured piece (differs from `to` for en passant).
    public var captureSquare: Int?
    public var promotion: CQLPieceKind?
    public var isEnPassant: Bool
    public var castling: CastlingSide?
    public var isNull: Bool

    public enum CastlingSide: Sendable, Hashable { case kingside, queenside }
}

/// A position in a game tree (a node of the PGN move tree).
public final class PositionNode: @unchecked Sendable {
    /// `positionid`: mainline positions are numbered by ply, variation positions follow in PGN order.
    public internal(set) var id: Int
    public private(set) weak var parent: PositionNode?
    public internal(set) var children: [PositionNode] = []
    /// Index of this node among its parent's children (0 = primary move).
    public let childIndex: Int
    public let ply: Int
    /// Number of secondary moves on the path from the initial position.
    public let depth: Int
    public let board: BoardState
    /// The move that led to this position (`nil` for the initial position).
    public let move: MoveInfo?
    /// Stable identity of the piece on each square (`nil` for empty squares).
    public let pieceIDs: [Int?]
    /// Comments present in the input PGN after the move leading here.
    public let originalComments: [String]
    /// NAG codes attached to the move leading here.
    public let nags: [Int]
    /// Full move number of the move to be played from this position.
    public let moveNumber: Int
    /// Path in the FischerCore annotated move tree.
    public let path: [Int]

    init(parent: PositionNode?, childIndex: Int, board: BoardState, move: MoveInfo?, pieceIDs: [Int?],
         comments: [String], nags: [Int], moveNumber: Int) {
        self.id = 0
        self.parent = parent
        self.childIndex = childIndex
        self.ply = (parent?.ply ?? -1) + 1
        self.depth = (parent?.depth ?? 0) + (parent != nil && childIndex > 0 ? 1 : 0)
        self.board = board
        self.move = move
        self.pieceIDs = pieceIDs
        self.originalComments = comments
        self.nags = nags
        self.moveNumber = moveNumber
        self.path = (parent?.path ?? []) + (parent == nil ? [] : [childIndex])
    }

    public var isInitial: Bool { parent == nil }
    public var isMainline: Bool { depth == 0 }
    public var sideToMove: CQLColor { board.sideToMove }

    public private(set) lazy var legalMoves: [MoveInfo] = board.legalMoves()

    public var isCheck: Bool { board.isInCheck(board.sideToMove) }
    public var isMate: Bool { isCheck && legalMoves.isEmpty }
    public var isStalemate: Bool { !isCheck && legalMoves.isEmpty }

    /// Whether `self` is an ancestor of (or equal to) `other`.
    public func isAncestor(of other: PositionNode) -> Bool {
        var current: PositionNode? = other
        while let node = current {
            if node === self { return true }
            if node.ply < ply { return false }
            current = node.parent
        }
        return false
    }

    /// `node` and its descendants in PGN order: a move, then the variations
    /// that branch off before it (each with its whole subtree), then the
    /// continuation. Iterative, so deep games do not exhaust the stack.
    static func pgnOrder(from node: PositionNode, children: (PositionNode) -> [PositionNode]) -> [PositionNode] {
        enum Item {
            case siblings([PositionNode])
            case subtree(PositionNode)
        }
        var ordered: [PositionNode] = []
        var stack: [Item] = [.subtree(node)]
        while let item = stack.popLast() {
            switch item {
            case .subtree(let root):
                ordered.append(root)
                stack.append(.siblings(children(root)))
            case .siblings(let list):
                guard let main = list.first else { continue }
                ordered.append(main)
                stack.append(.siblings(children(main)))
                for variation in list.dropFirst().reversed() { stack.append(.subtree(variation)) }
            }
        }
        return ordered
    }

    /// The square of the piece with the given identity, if it is on the board.
    public func square(ofPiece id: Int) -> Int? {
        pieceIDs.firstIndex(of: id)
    }
}

/// A game read from PGN, expanded into a tree of positions.
public final class GameTree: @unchecked Sendable {
    public let root: PositionNode
    /// All nodes in PGN order (a move, then the variations branching from
    /// before it, then the continuation).
    public let nodes: [PositionNode]
    public let tags: [String: String]
    public let source: AnnotatedPGNGame
    /// 1-based index of the game in its input.
    public let gameNumber: Int
    /// Byte offset where the game starts in its input (0 when unknown).
    public let byteOffset: Int64

    public init(game: AnnotatedPGNGame, gameNumber: Int, byteOffset: Int64 = 0) {
        self.source = game
        self.gameNumber = gameNumber
        self.byteOffset = byteOffset
        var tags: [String: String] = [:]
        for (tag, value) in game.tags { tags[tag.rawValue] = value }
        self.tags = tags

        let start = game.tree.initialGame
        let root = PositionNode(parent: nil, childIndex: 0, board: BoardState(game: start), move: nil,
                                pieceIDs: Self.pieceIDs(start), comments: game.tree.initialAnnotations.comments,
                                nags: [], moveNumber: Int(start.fullmoves))

        // Built iteratively: games can be hundreds of plies long.
        var work: [(PositionNode, Game, [AnnotatedMoveNode])] = [(root, start, game.tree.children)]
        while let (parent, parentGame, children) = work.popLast() {
            for (index, child) in children.enumerated() {
                var next = parentGame
                guard (try? next.execute(resolvedMove: child.move, considerHalfmoves: false)) != nil else { continue }
                let info = MoveInfo(board: parent.board, resolved: child.move)
                let nags = child.annotations.nags.map(\.rawValue) + child.annotations.otherNAGCodes
                let node = PositionNode(parent: parent, childIndex: index, board: BoardState(game: next), move: info,
                                        pieceIDs: Self.pieceIDs(next), comments: child.annotations.comments,
                                        nags: nags, moveNumber: Int(next.fullmoves))
                parent.children.append(node)
                work.append((node, next, child.children))
            }
        }
        self.root = root
        self.nodes = PositionNode.pgnOrder(from: root) { $0.children }

        // positionid: mainline by ply, then variation positions in PGN order.
        var nextID = 0
        for node in nodes where node.isMainline { node.id = node.ply; nextID = max(nextID, node.ply + 1) }
        for node in nodes where !node.isMainline { node.id = nextID; nextID += 1 }
    }

    deinit {
        // Break parent→child links so nodes are released one by one rather
        // than through a deep recursive chain of deinitializers.
        for node in nodes { node.children = [] }
    }

    private static func pieceIDs(_ game: Game) -> [Int?] {
        Square.allCases.map { game.pieceID(at: $0)?.rawValue }
    }

    /// Reads every game in a PGN string, throwing on the first game that
    /// cannot be read. Use ``read(pgn:)`` to skip unreadable games instead.
    public static func games(fromPGN text: String) throws -> [GameTree] {
        let (games, errors) = read(pgn: text)
        if let first = errors.first { throw first }
        return games
    }

    /// Reads every game in a PGN string, collecting the games that cannot be
    /// read instead of stopping at the first one. Game numbers keep their
    /// position in the input.
    public static func read(pgn text: String) -> (games: [GameTree], errors: [GameReadError]) {
        var games: [GameTree] = []
        var errors: [GameReadError] = []
        for chunk in PGNGameSplitter.chunks(in: Data(text.utf8)) {
            do {
                games.append(GameTree(game: try chunk.annotatedGame(), gameNumber: chunk.index + 1,
                                      byteOffset: chunk.startByteOffset))
            } catch {
                errors.append(GameReadError(gameNumber: chunk.index + 1, byteOffset: chunk.startByteOffset,
                                            reason: String(describing: error)))
            }
        }
        return (games, errors)
    }

    public var mainline: [PositionNode] {
        var result = [root]
        while let next = result.last!.children.first { result.append(next) }
        return result
    }
}

// MARK: - FischerCore bridging

extension CQLColor {
    init(_ color: PlayerColor) { self = color.isWhite() ? .white : .black }
}

extension CQLPieceKind {
    init(_ kind: Piece.Kind) {
        switch kind {
        case .pawn: self = .pawn
        case .knight: self = .knight
        case .bishop: self = .bishop
        case .rook: self = .rook
        case .queen: self = .queen
        case .king: self = .king
        }
    }
}

extension CQLPiece {
    init(_ piece: Piece) { self.init(CQLPieceKind(piece.kind), CQLColor(piece.color)) }
}

extension PromotionPiece {
    init?(kind: CQLPieceKind) {
        switch kind {
        case .queen: self = .queen
        case .rook: self = .rook
        case .bishop: self = .bishop
        case .knight: self = .knight
        default: return nil
        }
    }
}

extension BoardState {
    init(game: Game) {
        var sets = Array(repeating: SquareSet.empty, count: 12)
        for space in game.board {
            guard let piece = space.piece else { continue }
            let square = Square(file: space.file, rank: space.rank).rawValue
            sets[CQLPiece(piece).bit].insert(square)
        }
        var castling: CastlingSet = []
        for right in game.castlingRights {
            switch right.stringValue {
            case "K": castling.insert(.whiteKingside)
            case "Q": castling.insert(.whiteQueenside)
            case "k": castling.insert(.blackKingside)
            case "q": castling.insert(.blackQueenside)
            default: break
            }
        }
        self.init(pieceSets: sets, sideToMove: CQLColor(game.playerTurn),
                  castling: castling, enPassantTarget: game.enPassantTarget?.rawValue)
    }
}

extension MoveInfo {
    init(board: BoardState, resolved: ResolvedMove) {
        let from = resolved.move.start.rawValue
        let to = resolved.move.end.rawValue
        let piece = board.piece(at: from)!
        var captured = board.piece(at: to)
        var captureSquare: Int? = captured == nil ? nil : to
        var isEnPassant = false
        if piece.kind == .pawn, from % 8 != to % 8, captured == nil {
            isEnPassant = true
            captureSquare = (from / 8) * 8 + to % 8
            captured = CQLPiece(.pawn, piece.color.opposite)
        }
        var castling: CastlingSide?
        if piece.kind == .king, abs(to % 8 - from % 8) == 2 {
            castling = to % 8 > from % 8 ? .kingside : .queenside
        }
        self.init(from: from, to: to, piece: piece, captured: captured, captureSquare: captureSquare,
                  promotion: resolved.promotion.map { CQLPieceKind($0.kind) },
                  isEnPassant: isEnPassant, castling: castling, isNull: false)
    }
}
