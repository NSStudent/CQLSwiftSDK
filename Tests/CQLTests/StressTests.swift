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
}
