import Testing
@testable import CQL

enum SamplePGN {
    static let scholarsMate = """
    [Event "Scholar"]
    [Site "Berlin"]
    [Date "1995.03.04"]
    [White "Kasparov, Garry"]
    [Black "Tal, Mikhail"]
    [Result "1-0"]
    [WhiteElo "2800"]
    [BlackElo "2700"]

    1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0
    """

    static let specialMoves = """
    [Event "Special"]
    [White "Fischer"]
    [Black "Spassky"]
    [Result "*"]

    1. e4 d5 2. e5 f5 3. exf6 Nc6 4. fxg7 Nf6 5. gxh8=Q Bg4 6. Nf3 Qd7 7. Bb5 O-O-O 8. O-O *
    """

    static let withVariations = """
    [Event "Variations"]
    [White "A"]
    [Black "B"]
    [Result "*"]

    1. e4 {King pawn} (1. d4 d5 2. c4 $1) 1... e5 2. Nf3 Nc6 *
    """

    static let all = [scholarsMate, specialMoves, withVariations].joined(separator: "\n\n")
}

@Suite("Engine")
struct EngineTests {
    func run(_ source: String, _ pgn: String = SamplePGN.all) throws -> CQLResult {
        try CQLEngine(source: source).run(pgn: pgn)
    }

    func matchedGames(_ source: String, _ pgn: String = SamplePGN.all) throws -> [Int] {
        try run(source, pgn).matches.map(\.gameNumber)
    }

    @Test func gamesAreRead() throws {
        let games = try GameTree.games(fromPGN: SamplePGN.all)
        #expect(games.count == 3)
        #expect(games[0].mainline.count == 8)
        #expect(games[1].mainline.count == 16)
        #expect(games[2].nodes.count == 8)
    }

    @Test func legalMoveGeneratorAgreesWithFischerCore() throws {
        for game in try GameTree.games(fromPGN: SamplePGN.all) {
            for node in game.nodes {
                let ours = Set(node.legalMoves.map { "\($0.from)-\($0.to)-\($0.promotion.map { "\($0.rawValue)" } ?? "")" })
                var start = game.source.tree.initialGame
                for index in node.path.indices {
                    let path = Array(node.path[...index])
                    guard let move = game.source.tree.node(at: .init(path))?.move else { continue }
                    try start.execute(resolvedMove: move, considerHalfmoves: false)
                }
                let theirs = start.availableMoves().count
                let oursFromTo = Set(node.legalMoves.map { "\($0.from)-\($0.to)" }).count
                #expect(oursFromTo == theirs, "game \(game.gameNumber) position \(node.id) fen \(node.board.fen)")
                _ = ours
            }
        }
    }

    @Test func mateAndStalemate() throws {
        let result = try run("cql() mate")
        #expect(result.matches.map(\.gameNumber) == [1])
        #expect(result.matches[0].matchedPositions == [7])
        #expect(try matchedGames("cql() stalemate").isEmpty)
        #expect(try matchedGames("cql() btm mate ♕f7").count == 1)
    }

    @Test func pieceDesignatorsAndCounting() throws {
        #expect(try matchedGames("cql() initial ♙==8 #▲==16 power △==39") == [1, 2, 3])
        #expect(try matchedGames("cql() ♕==2") == [2])     // after gxh8=Q
        #expect(try matchedGames("cql() ♙d4") == [])       // variations are not searched by default
        #expect(try matchedGames("cql(variations) ♙d4") == [3])
    }

    @Test func movesAndCurrentMoveFilters() throws {
        #expect(try matchedGames("cql() ♕×f7") == [1])
        #expect(try matchedGames("cql() ――(enpassant)") == [2])
        #expect(try matchedGames("cql() ♙×h8=♕") == [2])
        #expect(try matchedGames("cql() o-o-o btm") == [])
        #expect(try matchedGames("cql() o-o-o wtm") == [2])
        #expect(try matchedGames("cql() o-o btm") == [2])
        #expect(try matchedGames("cql() enpassantsquare == f5") == [2])
        let castle = try run("cql() o-o x = from y = to ///\"from \" x \" to \" y", SamplePGN.specialMoves)
        #expect(castle.matches[0].comments.map(\.text) == ["from [e1,h1] to [f1,g1]"])
        let knight = try run("cql() initial x = ♘――(to) /// x", SamplePGN.scholarsMate)
        #expect(knight.matches.isEmpty)
        let pawn = try run("cql() initial x = ♙――(to) /// x", SamplePGN.scholarsMate)
        #expect(pawn.matches[0].comments.map(\.text) == ["e4"])
    }

    @Test func legalMoves() throws {
        #expect(try matchedGames("cql() initial countmoves legal ―― == 20") == [1, 2, 3])
        #expect(try matchedGames("cql() mate countmoves legal ―― == 0") == [1])
        #expect(try matchedGames("cql() legal ――(o-o-o) btm") == [2])
    }

    @Test func attacksAndPins() throws {
        // After 3. Qh5 the queen attacks f7 and e5.
        #expect(try matchedGames("cql() ♕→f7 ♕→e5 btm", SamplePGN.scholarsMate) == [1])
        #expect(try matchedGames("cql() initial ▦←♕ == [c1,c2,d2,e2,e1]", SamplePGN.scholarsMate) == [1])
        #expect(try matchedGames("cql() initial #(▦←♘) == 6", SamplePGN.scholarsMate) == [1])
        // 7. Bb5 pins the c6 knight against the queen on d7? No: the queen blocks; c6 is pinned to d7.
        #expect(try matchedGames("cql() pin from ♗ through ♞ to ♛", SamplePGN.specialMoves) == [1])
        // After 5. gxh8=Q the f8 bishop is pinned against the black king.
        #expect(try matchedGames("cql() pin == f8 ♕h8", SamplePGN.specialMoves) == [1])
        #expect(try matchedGames("cql() ♗→♞→♛", SamplePGN.specialMoves) == [1])
        #expect(try matchedGames("cql() check", SamplePGN.scholarsMate) == [1])
    }

    @Test func directionsAndSquares() throws {
        #expect(try matchedGames("cql() initial up 1 e2 == e3 #up e2 == 6 #diagonal 1 d4 == 4") == [1, 2, 3])
        #expect(try matchedGames("cql() initial rank ♔ == 1 file ♔ == 5 between(a1 h8) == [b2,c3,d4,e5,f6,g7]") == [1, 2, 3])
        #expect(try matchedGames("cql() initial light ♗ == f1 dark ♝ == f8 makesquare(5 1) == e1") == [1, 2, 3])
    }

    @Test func iterationAndVariables() throws {
        #expect(try matchedGames("cql() initial 8 == x∊♙ up 1 x & □") == [1, 2, 3])
        #expect(try matchedGames("cql() initial square all z in ♙ rank z == 2") == [1, 2, 3])
        #expect(try matchedGames("cql() initial piece k1 = ♔ find {k1 == g1}") == [2])
        #expect(try matchedGames("cql() cnt = 0 cnt += 5 cnt *= 2 cnt == 10 initial") == [1, 2, 3])
    }

    @Test func gameTreeNavigation() throws {
        #expect(try matchedGames("cql() initial find mate") == [1])
                #expect(try matchedGames("cql() ply == 3 parent:ply == 2 child:ply == 4") == [1, 2, 3])
        #expect(try matchedGames("cql() initial find all check == 1") == [1])
        #expect(try matchedGames("cql() initial 2 == find all ――(o-o or o-o-o)") == [2])
        #expect(try matchedGames("cql(variations) variation ply == 3 positionid > 4") == [3])
    }

    @Test func transforms() throws {
        // The white queen captures on f7; flipcolor also finds black queen captures on f2.
        #expect(try matchedGames("cql() flipcolor ♛×f2") == [1])
        #expect(try run("cql() flip ♕f7").matches.map(\.matchedPositions) == [[7]])
        // One of the images of ♕h5 is ♕d1, so every early position matches.
        #expect(try run("cql() flip ♕h5", SamplePGN.scholarsMate).matches[0].matchedPositions == [0, 1, 2, 3, 4, 5, 6])
        #expect(try matchedGames("cql() shift {♔g1 ♖f1}") == [2])
        #expect(try run("cql() initial x = flipcolor count ♙e2 /// x", SamplePGN.scholarsMate).matches[0].comments.map(\.text) == ["2"])
    }

    @Test func tagsAndStrings() throws {
        #expect(try matchedGames("cql() player white ~~ \"Kas.*v\" initial") == [1])
        #expect(try matchedGames("cql() player \"Tal\" initial") == [1])
        #expect(try matchedGames("cql() elo white > 2750 year == 1995 initial") == [1])
        #expect(try matchedGames("cql() result 1-0 initial") == [1])
        #expect(try matchedGames("cql() \"mate\"[1:-1] == \"at\" #\"pin\" == 3 int \"32\" + 1 == 33 initial") == [1, 2, 3])
        #expect(try matchedGames("cql() initial fen == \"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1\"") == [1, 2, 3])
        #expect(try matchedGames("cql() fen \"r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR\"") == [1])
        #expect(try matchedGames("cql(variations) originalcomment \"King\"") == [3])
        #expect(try matchedGames("cql(variations) originalcomment \"!\"") == [3])
    }

    @Test func functionsAndControlFlow() throws {
        let source = """
        cql()
        function Material(side) { power side }
        initial
        Material(△) == Material(▲)
        if wtm 1 else 2
        """
        #expect(try matchedGames(source) == [1, 2, 3])
        #expect(try matchedGames("cql() mate {x = 0 while (x < 5) x += 1 x == 5}") == [1])
    }

    @Test func sortingAndOutput() throws {
        let result = try run("cql() sort \"plies\" ply terminal")
        #expect(result.matches.map(\.gameNumber) == [2, 1, 3])
        let pgn = result.outputPGN
        #expect(pgn.contains("Game number 2"))
        #expect(pgn.contains("{ CQL }"))
    }

    @Test func matchCountAndEcho() throws {
        #expect(try matchedGames("cql(matchcount 3 100) check or mate or stalemate or o-o") == [])
        #expect(try matchedGames("cql(matchcount 0) mate") == [2, 3])
        #expect(try matchedGames("cql() initial echo (s t) { t:mate }") == [1])
    }

    @Test func runtimeErrors() {
        #expect(throws: CQLError.self) { try matchedGames("cql() x > 2") }
    }
}
