extension MoveInfo {
    /// The rook's origin and destination for a castling move.
    var castlingRook: (from: Int, to: Int)? {
        guard let castling else { return nil }
        let rank = from / 8
        return castling == .kingside ? (rank * 8 + 7, rank * 8 + 5) : (rank * 8, rank * 8 + 3)
    }

    /// Origin squares of the moving pieces (king and rook for castling).
    var fromSquares: SquareSet {
        var result = SquareSet(index: from)
        if let rook = castlingRook { result.insert(rook.from) }
        return result
    }

    /// Destination squares of the moving pieces (king and rook for castling).
    var toSquares: SquareSet {
        var result = SquareSet(index: to)
        if let rook = castlingRook { result.insert(rook.to) }
        return result
    }
}

extension BoardState {
    /// The position after `move` (no legality checks).
    func applying(_ move: MoveInfo) -> BoardState {
        var next = self
        guard !move.isNull else {
            next.sideToMove = sideToMove.opposite
            next.enPassantTarget = nil
            return next
        }
        if let captureSquare = move.captureSquare {
            for bit in 0..<12 { next.pieceSets[bit].remove(captureSquare) }
        }
        next.pieceSets[move.piece.bit].remove(move.from)
        let placed = move.promotion.map { CQLPiece($0, move.piece.color) } ?? move.piece
        next.pieceSets[placed.bit].insert(move.to)
        if let rook = move.castlingRook {
            let rookPiece = CQLPiece(.rook, move.piece.color)
            next.pieceSets[rookPiece.bit].remove(rook.from)
            next.pieceSets[rookPiece.bit].insert(rook.to)
        }
        next.enPassantTarget = nil
        if move.piece.kind == .pawn, abs(move.to - move.from) == 16 {
            next.enPassantTarget = (move.from + move.to) / 2
        }
        // Castling rights.
        func clear(_ square: Int) {
            switch square {
            case 4: next.castling.subtract([.whiteKingside, .whiteQueenside])
            case 60: next.castling.subtract([.blackKingside, .blackQueenside])
            case 0: next.castling.remove(.whiteQueenside)
            case 7: next.castling.remove(.whiteKingside)
            case 56: next.castling.remove(.blackQueenside)
            case 63: next.castling.remove(.blackKingside)
            default: break
            }
        }
        clear(move.from)
        clear(move.to)
        next.sideToMove = sideToMove.opposite
        return next
    }

    /// Pseudolegal moves: legal except that the mover's king may be left in check.
    /// Castling still requires the king not to pass through or start in check.
    func pseudolegalMoves() -> [MoveInfo] {
        var moves: [MoveInfo] = []
        let us = sideToMove
        let own = squares(ofColor: us)
        let enemy = squares(ofColor: us.opposite)
        let occupied = own | enemy
        let promotionRank = us == .white ? 7 : 0

        func add(_ piece: CQLPiece, _ from: Int, _ to: Int, enPassant: Bool = false) {
            var captured = self.piece(at: to)
            var captureSquare: Int? = captured == nil ? nil : to
            if enPassant {
                captureSquare = (from / 8) * 8 + to % 8
                captured = CQLPiece(.pawn, us.opposite)
            }
            if piece.kind == .pawn, to / 8 == promotionRank {
                for kind in [CQLPieceKind.queen, .rook, .bishop, .knight] {
                    moves.append(MoveInfo(from: from, to: to, piece: piece, captured: captured, captureSquare: captureSquare,
                                          promotion: kind, isEnPassant: false, castling: nil, isNull: false))
                }
            } else {
                moves.append(MoveInfo(from: from, to: to, piece: piece, captured: captured, captureSquare: captureSquare,
                                      promotion: nil, isEnPassant: enPassant, castling: nil, isNull: false))
            }
        }

        for kind in CQLPieceKind.allCases {
            let piece = CQLPiece(kind, us)
            for from in squares(of: piece) {
                if kind == .pawn {
                    let forward: BoardDirection = us == .white ? .up : .down
                    if let one = Attacks.step(from, forward), !occupied.contains(one) {
                        add(piece, from, one)
                        let startRank = us == .white ? 1 : 6
                        if from / 8 == startRank, let two = Attacks.step(one, forward), !occupied.contains(two) {
                            add(piece, from, two)
                        }
                    }
                    for target in Attacks.pawnAttackTable[us.rawValue][from] {
                        if enemy.contains(target) {
                            add(piece, from, target)
                        } else if target == enPassantTarget {
                            add(piece, from, target, enPassant: true)
                        }
                    }
                } else {
                    for target in Attacks.attacks(of: piece, from: from, occupied: occupied) where !own.contains(target) {
                        add(piece, from, target)
                    }
                }
            }
        }

        // Castling.
        if let king = kingSquare(us), !isAttacked(king, by: us.opposite) {
            let rank = us == .white ? 0 : 7
            let options: [(CastlingSet, MoveInfo.CastlingSide, [Int], [Int])] = us == .white
                ? [(.whiteKingside, .kingside, [5, 6], [5, 6]), (.whiteQueenside, .queenside, [1, 2, 3], [2, 3])]
                : [(.blackKingside, .kingside, [61, 62], [61, 62]), (.blackQueenside, .queenside, [57, 58, 59], [58, 59])]
            for (right, side, empty, safe) in options where castling.contains(right) && king == rank * 8 + 4 {
                let rookSquare = side == .kingside ? rank * 8 + 7 : rank * 8
                guard squares(of: CQLPiece(.rook, us)).contains(rookSquare),
                      empty.allSatisfy({ !occupied.contains($0) }),
                      safe.allSatisfy({ !isAttacked($0, by: us.opposite) }) else { continue }
                let to = side == .kingside ? rank * 8 + 6 : rank * 8 + 2
                moves.append(MoveInfo(from: king, to: to, piece: CQLPiece(.king, us), captured: nil, captureSquare: nil,
                                      promotion: nil, isEnPassant: false, castling: side, isNull: false))
            }
        }
        return moves
    }

    /// Plays `from`→`to` if it is a legal move here, returning the move and
    /// the resulting position; `nil` if it is not legal.
    ///
    /// Castling is given as the king's move (e1→g1); the "king takes rook"
    /// form (e1→h1) is accepted too. `promotion` is required exactly when a
    /// pawn reaches the last rank.
    func play(from: Int, to target: Int, promotion: CQLPieceKind?) -> (MoveInfo, BoardState)? {
        guard let piece = piece(at: from), piece.color == sideToMove, from != target else { return nil }
        let us = sideToMove
        let own = squares(ofColor: us)
        let occupied = self.occupied
        var to = target
        var castlingSide: MoveInfo.CastlingSide?

        if piece.kind == .king, from / 8 == to / 8, from == (us == .white ? 4 : 60),
           abs(to - from) == 2 || squares(of: CQLPiece(.rook, us)).contains(to) && (to % 8 == 0 || to % 8 == 7) {
            // Castling, possibly written as the king capturing its own rook.
            let side: MoveInfo.CastlingSide = to > from ? .kingside : .queenside
            let rank = from / 8
            let right: CastlingSet = us == .white
                ? (side == .kingside ? .whiteKingside : .whiteQueenside)
                : (side == .kingside ? .blackKingside : .blackQueenside)
            let rookSquare = side == .kingside ? rank * 8 + 7 : rank * 8
            let empty = side == .kingside ? [rank * 8 + 5, rank * 8 + 6] : [rank * 8 + 1, rank * 8 + 2, rank * 8 + 3]
            let path = side == .kingside ? [from, rank * 8 + 5, rank * 8 + 6] : [from, rank * 8 + 3, rank * 8 + 2]
            guard castling.contains(right), squares(of: CQLPiece(.rook, us)).contains(rookSquare),
                  empty.allSatisfy({ !occupied.contains($0) }),
                  path.allSatisfy({ !isAttacked($0, by: us.opposite) }) else { return nil }
            to = side == .kingside ? rank * 8 + 6 : rank * 8 + 2
            castlingSide = side
        } else if own.contains(to) {
            return nil
        }

        var captured = self.piece(at: to)
        var captureSquare: Int? = captured == nil ? nil : to
        var isEnPassant = false
        if castlingSide == nil {
            switch piece.kind {
            case .pawn:
                let forward = us == .white ? 8 : -8
                let startRank = us == .white ? 1 : 6
                if to == from + forward {
                    guard captured == nil else { return nil }
                } else if to == from + 2 * forward {
                    guard from / 8 == startRank, captured == nil, !occupied.contains(from + forward) else { return nil }
                } else if Attacks.pawnAttackTable[us.rawValue][from].contains(to) {
                    if captured == nil {
                        guard to == enPassantTarget else { return nil }
                        isEnPassant = true
                        captureSquare = (from / 8) * 8 + to % 8
                        captured = CQLPiece(.pawn, us.opposite)
                    }
                } else {
                    return nil
                }
                let lastRank = us == .white ? 7 : 0
                if to / 8 == lastRank {
                    guard let promotion, [.queen, .rook, .bishop, .knight].contains(promotion) else { return nil }
                } else if promotion != nil {
                    return nil
                }
            default:
                guard Attacks.attacks(of: piece, from: from, occupied: occupied).contains(to) else { return nil }
            }
        }

        let move = MoveInfo(from: from, to: to, piece: piece, captured: captured, captureSquare: captureSquare,
                            promotion: piece.kind == .pawn ? promotion : nil, isEnPassant: isEnPassant,
                            castling: castlingSide, isNull: false)
        let next = applying(move)
        guard !next.isInCheck(us) else { return nil }
        return (move, next)
    }

    func legalMoves() -> [MoveInfo] {
        pseudolegalMoves().filter { !applying($0).isInCheck(sideToMove) }
    }

    /// FEN of this position with halfmove clock 0 and fullmove number 1.
    var fen: String {
        var rows: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var row = ""
            var empty = 0
            for file in 0..<8 {
                if let piece = piece(at: rank * 8 + file) {
                    if empty > 0 { row += String(empty); empty = 0 }
                    row.append(piece.asciiLetter)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { row += String(empty) }
            rows.append(row)
        }
        var rights = ""
        if castling.contains(.whiteKingside) { rights += "K" }
        if castling.contains(.whiteQueenside) { rights += "Q" }
        if castling.contains(.blackKingside) { rights += "k" }
        if castling.contains(.blackQueenside) { rights += "q" }
        let ep = enPassantTarget.map(SquareName.name(of:)) ?? "-"
        return "\(rows.joined(separator: "/")) \(sideToMove == .white ? "w" : "b") \(rights.isEmpty ? "-" : rights) \(ep) 0 1"
    }
}
