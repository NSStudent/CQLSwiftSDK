import FischerCore
import Testing
@testable import CQL

@Suite("Stress")
struct StressTests {
    /// A deterministic game of up to `plies` random legal moves.
    static func randomGamePGN(plies: Int, seed: UInt64 = 42) throws -> String {
        var game = Game()
        var state = seed
        for _ in 0..<plies {
            let moves = game.availableMoves()
            guard !moves.isEmpty else { break }
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let move = moves[Int(state >> 33) % moves.count]
            try game.execute(resolvedMove: ResolvedMove(move: move, promotion: .queen), considerHalfmoves: false)
        }
        return AnnotatedPGNGame(game: game, tags: [.event: "Random", .white: "W", .black: "B"]).pgn()
    }

    @Test func longPathsDoNotOverflowTheStack() throws {
        let pgn = try Self.randomGamePGN(plies: 300)
        let games = try GameTree.games(fromPGN: pgn)
        let plies = games[0].mainline.count - 1
        #expect(plies > 100)
        let result = try CQLEngine(source: "cql() initial {x = ⊢ ―― *} /// x").run(games: games)
        #expect(result.matches.first?.comments.map(\.text) == ["\(plies)"])
    }

    @Test func pathFromEveryPositionIsFastEnough() throws {
        let games = try GameTree.games(fromPGN: try Self.randomGamePGN(plies: 300))
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            _ = try CQLEngine(source: "cql() ⊢ (△―― ▲――)+ ").run(games: games)
        }
        #expect(elapsed < .seconds(20))
    }

    /// The incremental tree builder must agree with FischerCore's replay at
    /// every position: placement, side to move, castling, en passant and
    /// piece identities.
    @Test(arguments: [1, 2, 3, 4, 5, 6] as [UInt64])
    func incrementalTreesMatchFischerCore(seed: UInt64) throws {
        let pgn = try Self.randomGamePGN(plies: 400, seed: seed)
        let tree = try #require(try GameTree.games(fromPGN: pgn).first)
        var game = tree.source.tree.initialGame
        var node = tree.root
        let moves = tree.source.tree.mainline.map(\.node.move)
        #expect(tree.mainline.count == moves.count + 1)
        for move in moves {
            try game.execute(resolvedMove: move, considerHalfmoves: false)
            node = try #require(node.children.first)
            let expected = BoardState(game: game)
            #expect(node.board.pieceSets == expected.pieceSets, "ply \(node.ply)")
            #expect(node.board.sideToMove == expected.sideToMove)
            #expect(node.board.castling == expected.castling, "ply \(node.ply)")
            #expect(node.board.enPassantTarget == expected.enPassantTarget, "ply \(node.ply)")
            #expect(node.pieceIDs == Square.allCases.map { game.pieceID(at: $0)?.rawValue }, "ply \(node.ply)")
            #expect(node.moveNumber == Int(game.fullmoves))
        }
        // Built from the same moves directly, the tree is identical.
        let direct = try GameTree(moves: moves)
        #expect(direct.mainline.map(\.board) == tree.mainline.map(\.board))
    }
}
