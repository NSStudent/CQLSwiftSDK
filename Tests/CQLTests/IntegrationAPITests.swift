import FischerCore
import Testing
@testable import CQL

@Suite("Decoded games")
struct DecodedGameTests {
    static let scholarsMoves: [ResolvedMove] = {
        var game = Game()
        var moves: [ResolvedMove] = []
        for san in ["e4", "e5", "Bc4", "Nc6", "Qh5", "Nf6", "Qxf7#"] {
            let before = game.moveHistory.count
            try! game.execute(san: san)
            let element = game.moveHistory[before]
            moves.append(ResolvedMove(move: element.move, promotion: element.promotionPiece))
        }
        return moves
    }()

    @Test func gamesBuiltFromMovesMatchLikePGN() throws {
        let engine = try CQLEngine(source: "cql() mate player white \"Kasparov\"")
        let tree = try GameTree(moves: Self.scholarsMoves, tags: ["White": "Kasparov, Garry", "Black": "X"])
        let match = try engine.evaluate(game: tree)
        #expect(match?.matchedPositions == [7])
        let fromPGN = try engine.run(pgn: SamplePGN.scholarsMate).matches.first
        #expect(fromPGN?.matchedPositions == match?.matchedPositions)
    }

    @Test func fischerCoreGamesCanBeEvaluated() throws {
        var game = Game()
        for san in ["e4", "e5", "Bc4", "Nc6", "Qh5", "Nf6", "Qxf7#"] { try game.execute(san: san) }
        let tree = try GameTree(game: game)
        #expect(try CQLEngine(source: "cql() mate").evaluate(game: tree)?.matchedPositions == [7])
    }

    @Test func startingPositionsAndIllegalMoves() throws {
        // Black to move from a FEN: …Qh4# is legal only in that position.
        let fen = "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2"
        let move = ResolvedMove(move: Square.d8 >>> Square.h4)
        let tree = try GameTree(moves: [move], startingFEN: fen)
        #expect(try CQLEngine(source: "cql() mate").evaluate(game: tree)?.matchedPositions == [1])
        #expect(throws: GameReadError.self) { try GameTree(moves: [move]) }
        #expect(throws: GameReadError.self) { try GameTree(moves: [], startingFEN: "not a fen") }
    }

    @Test func pgnOutputIsProducedOnDemand() throws {
        let tree = try GameTree(moves: Self.scholarsMoves, tags: ["White": "W", "Black": "B", "Event": "E"])
        let match = try #require(try CQLEngine(source: "cql() mate /// \"mate!\"").evaluate(game: tree))
        let pgn = match.annotatedPGN
        #expect(pgn.contains("Qxf7#"))
        #expect(pgn.contains("mate!"))
        #expect(pgn.contains("[White \"W\"]"))
    }
}

@Suite("Necessary conditions")
struct PlanTests {
    func plan(_ source: String) throws -> NecessaryConditions {
        try Parser.parse(source).necessaryConditions
    }

    func squares(_ text: String) -> SquareSet {
        guard case .pieceDesignator(let designator) = try! Lexer.tokenize(text)[0].kind else { fatalError() }
        return designator.squares
    }

    @Test func isolatedQueenPawn() throws {
        let conditions = try plan("cql() Pd4 and not P[c2-7,e2-7] and not [Pp][c2-7,d5-7]")
        #expect(conditions.isExact)
        let pieces = conditions.position.pieces
        #expect(pieces.count == 3)
        #expect(pieces[0] == .init(pieces: PieceTypeSet(CQLPiece(.pawn, .white)), squares: squares("d4"), count: 1...64))
        #expect(pieces[1].count == 0...0)
        #expect(pieces[1].squares == squares("[c2-7,e2-7]"))
        #expect(pieces[2].pieces == PieceTypeSet(CQLPiece(.pawn, .white)).union(PieceTypeSet(CQLPiece(.pawn, .black))))
        #expect(pieces[2].squaresByPiece.count == 2)
    }

    @Test func countsTagsAndSideToMove() throws {
        let conditions = try plan("""
        cql(result 1-0) btm 4 ≤ ♙ < 7 #♕ == 1 elo white >= 2500 2000 <= year player black "Tal" fen "8/8/8/8/8/8/8/8"
        sort "x" ♜ > 1
        /// "comment"
        """)
        #expect(conditions.isExact)
        #expect(conditions.position.sideToMove == .black)
        #expect(conditions.position.pieces.map(\.count) == [0...6, 4...64, 1...1, 2...64])
        #expect(conditions.game.result == "1-0")
        #expect(conditions.game.elo == [.init(side: .white, range: 2500...Int.max)])
        #expect(conditions.game.year == 2000...Int.max)
        #expect(conditions.game.substrings == [.init(tags: ["Black"], text: "Tal")])
        #expect(conditions.position.placements == ["8/8/8/8/8/8/8/8"])
    }

    @Test func untranslatedPartsMakeThePlanInexact() throws {
        let conditions = try plan("cql() Pd4 pin from R")
        #expect(!conditions.isExact)
        #expect(conditions.position.pieces.count == 1)
        #expect(conditions.untranslated.count == 1)
        #expect(try !plan("cql() mate").isExact)
        #expect(try !plan("cql() flipcolor Pd4").isExact)
        #expect(try !plan("cql() Pd4 or Pe4").isExact)
        #expect(try plan("cql(variations) Q").searchesVariations)
    }

    @Test func matchcountZeroGivesNoConditions() throws {
        let conditions = try plan("cql(matchcount 0) Q")
        #expect(!conditions.isExact)
        #expect(conditions.position.isEmpty)
    }

    @Test func subfiltersWalkTheTree() throws {
        let program = try Parser.parse("cql() check or {Q mate}")
        #expect(program.body.contains { if case .keyword("mate") = $0 { true } else { false } })
        #expect(!program.body.contains { if case .keyword("stalemate") = $0 { true } else { false } })
    }
}
