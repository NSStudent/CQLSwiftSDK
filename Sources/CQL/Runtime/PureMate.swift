/// Pure, model and ideal mates and stalemates (Encyclopedia of Chess Problems
/// definitions, as adopted by CQL 6.2). See Docs/Reference/01-language-core.md §5.3.
///
/// All computations are for the side to move (the mated/stalemated side),
/// so they are colour-symmetric.
extension BoardState {
    /// A pin of `pinned` against its own king by `pinner`.
    struct Pin {
        var pinner: Int
        var pinned: Int
    }

    /// Pins of `color`'s pieces against `color`'s king.
    func pins(against color: CQLColor) -> [Pin] {
        guard let king = kingSquare(color) else { return [] }
        let occupied = self.occupied
        let own = squares(ofColor: color)
        let enemy = color.opposite
        var result: [Pin] = []
        for direction in BoardDirection.allCases {
            let sliders = direction.isOrthogonal
                ? squares(of: CQLPiece(.rook, enemy)) | squares(of: CQLPiece(.queen, enemy))
                : squares(of: CQLPiece(.bishop, enemy)) | squares(of: CQLPiece(.queen, enemy))
            var square = king
            var candidate: Int?
            while let next = Attacks.step(square, direction) {
                square = next
                guard occupied.contains(next) else { continue }
                if candidate == nil {
                    guard own.contains(next) else { break }
                    candidate = next
                } else {
                    if sliders.contains(next) { result.append(Pin(pinner: next, pinned: candidate!)) }
                    break
                }
            }
        }
        return result
    }

    /// Pieces of `color` that attack `square`, with `occupied` as blockers.
    func attackers(of square: Int, color: CQLColor, occupied: SquareSet) -> SquareSet {
        var result = SquareSet()
        for from in squares(ofColor: color) {
            let piece = piece(at: from)!
            if Attacks.attacks(of: piece, from: from, occupied: occupied).contains(square) { result.insert(from) }
        }
        return result
    }

    /// Whether the piece on `from` could move to `target`, ignoring checks and pins.
    func canReach(_ from: Int, _ target: Int) -> Bool {
        guard let piece = piece(at: from), !squares(ofColor: piece.color).contains(target) else { return false }
        let occupied = self.occupied
        if piece.kind == .pawn {
            let forward: BoardDirection = piece.color == .white ? .up : .down
            if let one = Attacks.step(from, forward), !occupied.contains(one) {
                if one == target { return true }
                let startRank = piece.color == .white ? 1 : 6
                if from / 8 == startRank, let two = Attacks.step(one, forward), two == target, !occupied.contains(two) {
                    return true
                }
            }
            return Attacks.pawnAttackTable[piece.color.rawValue][from].contains(target)
                && (occupied.contains(target) || target == enPassantTarget)
        }
        return Attacks.attacks(of: piece, from: from, occupied: occupied).contains(target)
    }

    /// Whether some non-king piece of `color` could move to one of `targets`.
    func hasRefuter(_ color: CQLColor, _ targets: SquareSet) -> Bool {
        for from in squares(ofColor: color) where piece(at: from)?.kind != .king {
            for target in targets where canReach(from, target) { return true }
        }
        return false
    }

    /// The single occupied square strictly between a slider on `from` and
    /// `target` along the slider's lines, if exactly one square blocks it.
    func soleBlocker(from: Int, to target: Int) -> Int? {
        guard let piece = piece(at: from), let direction = Attacks.direction(from: from, to: target) else { return nil }
        switch piece.kind {
        case .rook where direction.isOrthogonal, .bishop where direction.isDiagonal, .queen: break
        default: return nil
        }
        let blockers = Attacks.between(from, target) & occupied
        return blockers.single
    }

    // MARK: - Pure mate

    /// Participants of a pure mate of the side to move, or `nil` if the
    /// position (already known to be mate) is not a pure mate.
    func pureMateParticipants() -> SquareSet? {
        let defender = sideToMove
        let attacker = defender.opposite
        guard let king = kingSquare(defender) else { return nil }
        let field = Attacks.kingTable[king]
        let occupied = self.occupied
        let withoutKing = occupied & ~SquareSet(index: king)
        let checkers = attackers(of: king, color: attacker, occupied: occupied)
        let isDoubleCheck = checkers.count > 1

        // Squares where a defender could break a single check.
        var refutation = SquareSet()
        for checker in checkers { refutation |= Attacks.between(checker, king) | SquareSet(index: checker) }

        let pins = self.pins(against: defender)
        func necessary(_ pin: Pin) -> Bool {
            guard !isDoubleCheck else { return false }
            return refutation.contains { canReach(pin.pinned, $0) }
        }

        // 1–3: guards on the king's field.
        var guarders = SquareSet()
        for square in field {
            let guards = attackers(of: square, color: attacker, occupied: withoutKing)
            guarders |= guards
            let occupant = piece(at: square)
            if occupant == nil || occupant?.color == attacker {
                guard guards.count == 1 else { return nil }
            } else if !guards.isEmpty {
                guard guards.count == 1,
                      let pin = pins.first(where: { $0.pinned == square }),
                      guards.contains(pin.pinner), necessary(pin) else { return nil }
            }
        }

        // 4: a double check must be necessary.
        if isDoubleCheck {
            guard checkers.count == 2 else { return nil }
            for checker in checkers {
                let squares = Attacks.between(checker, king) | SquareSet(index: checker)
                guard hasRefuter(defender, squares) else { return nil }
            }
        }

        // Participants.
        var participants = checkers | guarders
        for pin in self.pins(against: attacker) { participants.insert(pin.pinned) }
        let potentialRefuters = squares(ofColor: defender).filter { from in
            piece(at: from)?.kind != .king && refutation.contains { canReach(from, $0) }
        }
        if !isDoubleCheck {
            for pin in pins where potentialRefuters.contains(pin.pinned) { participants.insert(pin.pinner) }
        }
        participants.insert(king)
        participants |= field & squares(ofColor: defender)
        if let attackerKing = kingSquare(attacker) {
            // Defender pieces blocking a defender check on the attacking king.
            for from in squares(ofColor: defender) {
                if let blocker = soleBlocker(from: from, to: attackerKing), squares(ofColor: defender).contains(blocker) {
                    participants.insert(blocker)
                }
            }
        }
        if !isDoubleCheck {
            for from in squares(ofColor: defender) where piece(at: from)?.kind != .king {
                for target in refutation {
                    guard let blocker = soleBlocker(from: from, to: target) else { continue }
                    // An attacking piece shielding the refutation square, or a
                    // defender piece blocking its own side's move there.
                    participants.insert(blocker)
                }
            }
        }
        return participants
    }

    // MARK: - Pure stalemate

    /// Participants of a pure stalemate of the side to move, or `nil` if the
    /// position (already known to be stalemate) is not a pure stalemate.
    func pureStalemateParticipants() -> SquareSet? {
        let defender = sideToMove
        let attacker = defender.opposite
        guard let king = kingSquare(defender) else { return nil }
        let occupied = self.occupied
        let pins = self.pins(against: defender)
        var attackedField = SquareSet()
        for square in Attacks.kingTable[king] {
            let attacks = attackers(of: square, color: attacker, occupied: occupied)
            attackedField |= attacks
            switch piece(at: square) {
            case nil:
                guard attacks.count == 1 else { return nil }
            case let occupant? where occupant.color == attacker:
                guard attacks.count == 1 else { return nil }
            default:
                if let pin = pins.first(where: { $0.pinned == square }) {
                    guard attacks.isEmpty || (attacks.count == 1 && attacks.contains(pin.pinner)) else { return nil }
                } else {
                    guard attacks.isEmpty else { return nil }
                }
            }
        }
        var participants = squares(ofColor: defender) | attackedField
        for pin in self.pins(against: attacker) { participants.insert(pin.pinned) }
        for pin in pins { participants.insert(pin.pinner) }
        return participants
    }

    /// Model (`model`) or ideal (`!model`) refinement of a set of participants.
    func refine(_ participants: SquareSet, model: Bool) -> SquareSet {
        if model {
            let attacker = sideToMove.opposite
            var officers = SquareSet()
            for kind in [CQLPieceKind.rook, .knight, .bishop, .queen] { officers |= squares(of: CQLPiece(kind, attacker)) }
            return officers.isSubset(of: participants) ? participants : .empty
        }
        return occupied == participants ? participants : .empty
    }
}
