import Testing
@testable import CQL

@Suite("Pure mates and stalemates")
struct PureMateTests {
    static func pgn(_ fen: String, _ moves: String) -> String {
        """
        [Event "?"]
        [White "W"]
        [Black "B"]
        [Result "*"]
        [SetUp "1"]
        [FEN "\(fen)"]

        \(moves) *
        """
    }

    func lastValue(_ filter: String, _ pgn: String) throws -> String? {
        let result = try CQLEngine(source: "cql() terminal x = \(filter) /// x").run(pgn: pgn)
        return result.matches.first?.comments.first?.text
    }

    /// Back-rank mate with the pawns as self-blocks: pure and model, but the
    /// white king and pawns do not take part, so it is not ideal.
    static let backRank = pgn("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1", "1. Ra8#")
    /// King and rook mate in the corner: every piece takes part.
    static let corner = pgn("k7/8/1K6/8/8/8/8/7R w - - 0 1", "1. Rh8#")

    @Test func backRankMateIsPureAndModel() throws {
        #expect(try lastValue("puremate", Self.backRank) == "[f7,g7,h7,a8,g8]")
        #expect(try lastValue("modelmate", Self.backRank) == "[f7,g7,h7,a8,g8]")
        #expect(try lastValue("idealmate", Self.backRank) == "[]")
    }

    @Test func cornerMateIsIdeal() throws {
        #expect(try lastValue("idealmate", Self.corner) == "[b6,a8,h8]")
    }

    @Test func scholarsMateIsNotPure() throws {
        // The f8 bishop, a self-block, is attacked by the queen.
        #expect(try lastValue("puremate", SamplePGN.scholarsMate) == "[]")
        #expect(try CQLEngine(source: "cql() puremate").run(pgn: SamplePGN.scholarsMate).matches.isEmpty)
    }

    @Test func pureStalemates() throws {
        let pure = Self.pgn("k7/8/1Q6/8/8/8/8/7K b - - 0 1", "")
        #expect(try lastValue("purestalemate", pure) == "[b6,a8]")
        #expect(try lastValue("modelstalemate", pure) == "[b6,a8]")
        #expect(try lastValue("idealstalemate", pure) == "[]")
        // b7 and b8 are attacked twice (king and queen).
        let impure = Self.pgn("k7/2K5/1Q6/8/8/8/8/8 b - - 0 1", "")
        #expect(try lastValue("purestalemate", impure) == "[]")
        #expect(try CQLEngine(source: "cql() stalemate").run(pgn: impure).matches.count == 1)
    }

    @Test func modelMateWorksForBothColours() throws {
        let blackMates = Self.pgn("r5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1", "1... Ra1#")
        #expect(try lastValue("modelmate", blackMates) == "[a1,g1,f2,g2,h2]")
    }

    @Test func necessaryPinMate() throws {
        // The g7 knight is pinned by the a1 bishop and guarded only by it; the
        // pin is necessary because the knight could otherwise interpose on e8.
        let pinMate = Self.pgn("7k/6np/8/8/8/8/R7/B3K3 w - - 0 1", "1. Ra8#")
        #expect(try lastValue("puremate", pinMate) == "[a1,g7,h7,a8,h8]")
        #expect(try lastValue("modelmate", pinMate) == "[a1,g7,h7,a8,h8]")
        // A second guard on the knight (the g1 rook) makes the mate impure.
        let guardedTwice = Self.pgn("7k/6np/8/8/8/8/R7/B3K1R1 w - - 0 1", "1. Ra8#")
        #expect(try lastValue("puremate", guardedTwice) == "[]")
    }
}

@Suite("consecutivemoves")
struct ConsecutiveMovesTests {
    /// After 1. e4 e5 both lines play ...Nc6, Bc4 and ...Nf6 in a row.
    static let transposition = """
    [Event "?"]
    [White "W"]
    [Black "B"]
    [Result "*"]

    1. e4 e5 2. Nf3 (2. Nc3 Nc6 3. Bc4 Nf6) 2... Nc6 3. Bc4 Nf6 *
    """

    func comments(_ source: String) throws -> [String] {
        try CQLEngine(source: source).run(pgn: Self.transposition).matches.first?.comments.map(\.text) ?? []
    }

    @Test func longestRunOfIdenticalMoves() throws {
        #expect(try comments("cql(variations) initial x = consecutivemoves quiet (position 6 position 10) /// x") == ["3"])
        #expect(try comments("cql(variations) initial x = consecutivemoves quiet (position 6 position 3) /// x") == ["0"])
    }

    @Test func rangeAndComments() throws {
        let annotated = try comments("cql(variations) initial src = position 6 dst = position 10 consecutivemoves 2 5 (src dst)")
        #expect(annotated.sorted() == ["dst-move[1]", "dst-move[2]", "dst-move[3]", "src-move[1]", "src-move[2]", "src-move[3]"])
        #expect(try comments("cql(variations) initial src = position 6 dst = position 10 consecutivemoves quiet 4 5 (src dst)").isEmpty)
    }
}
