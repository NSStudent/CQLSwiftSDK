import Foundation
import Testing
@testable import CQL

@Suite("Reading PGN input")
struct ReadingTests {
    /// Game 2 has an invalid FEN tag and cannot be read.
    static let withBrokenGame = """
    [Event "First"]
    [White "A"]
    [Black "B"]
    [Result "1-0"]

    1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0

    [Event "Broken"]
    [SetUp "1"]
    [FEN "not a fen"]

    1. e4 *

    [Event "Third"]
    [White "C"]
    [Black "D"]
    [Result "*"]

    1. d4 d5 *
    """

    @Test func unreadableGamesAreSkippedByDefault() throws {
        let result = try CQLEngine(source: "cql() initial").run(pgn: Self.withBrokenGame)
        #expect(result.matches.map(\.gameNumber) == [1, 3])
        #expect(result.gamesExamined == 2)
        #expect(result.skippedGames.map(\.gameNumber) == [2])
        #expect(result.skippedGames.first?.reason.contains("invalidFEN") == true)
        #expect(result.skippedGames.first.map { $0.byteOffset > 0 } == true)
    }

    @Test func gameNumbersKeepTheirPositionInTheInput() throws {
        #expect(try CQLEngine(source: "cql() initial gamenumber == 3").run(pgn: Self.withBrokenGame)
            .matches.map(\.gameNumber) == [3])
    }

    @Test func abortStopsTheRun() {
        var options = CQLEngine.Options()
        options.onInvalidGame = { _ in .abort }
        #expect(throws: CQLError.self) {
            try CQLEngine(source: "cql() initial", options: options).run(pgn: Self.withBrokenGame)
        }
    }

    @Test func theCallbackSeesEveryUnreadableGame() throws {
        final class Log: @unchecked Sendable { var games: [Int] = [] }
        let log = Log()
        var options = CQLEngine.Options()
        options.onInvalidGame = { error in
            log.games.append(error.gameNumber)
            return .skip
        }
        _ = try CQLEngine(source: "cql() initial", options: options).run(pgn: Self.withBrokenGame)
        #expect(log.games == [2])
    }

    @Test func gamesOutsideTheGameNumberRangeAreNotRead() throws {
        let result = try CQLEngine(source: "cql(gamenumber 3) initial").run(pgn: Self.withBrokenGame)
        #expect(result.skippedGames.isEmpty)
        #expect(result.matches.map(\.gameNumber) == [3])
    }

    @Test func partiallyReadGamesAreReported() throws {
        let pgn = """
        [Event "Illegal"]
        [Result "*"]

        1. e4 e5 2. Ke3 Qh4 *
        """
        let result = try CQLEngine(source: "cql() initial").run(pgn: pgn)
        #expect(result.matches.count == 1)
        #expect(result.partiallyReadGames.map(\.gameNumber) == [1])
        #expect(result.partiallyReadGames.first?.reason.contains("Ke3") == true)
    }

    @Test func gameTreeReadCollectsErrors() throws {
        let (games, errors) = GameTree.read(pgn: Self.withBrokenGame)
        #expect(games.map(\.gameNumber) == [1, 3])
        #expect(errors.map(\.gameNumber) == [2])
        #expect(throws: GameReadError.self) { try GameTree.games(fromPGN: Self.withBrokenGame) }
    }

    @Test func filesAreReadIncrementallyIncludingLatin1() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("games.pgn")
        // "Andrés" encoded as Latin-1, followed by the other games.
        var data = Data("[Event \"Latin\"]\n[White \"Andr".utf8)
        data.append(0xE9)
        data.append(Data("s\"]\n[Black \"X\"]\n[Result \"*\"]\n\n1. e4 *\n\n".utf8))
        data.append(Data(Self.withBrokenGame.utf8))
        try data.write(to: url)

        // A tiny block size exercises games split across reads.
        let result = try CQLEngine(source: "cql() initial").run(contentsOf: url, blockSize: 7)
        #expect(result.matches.map(\.gameNumber) == [1, 2, 4])
        #expect(result.skippedGames.map(\.gameNumber) == [3])
        #expect(result.matches.first?.game.tags["White"] == "Andrés")
    }
}
