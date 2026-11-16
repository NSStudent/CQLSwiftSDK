import Testing
@testable import CQL

@Suite("Path (⊢)")
struct PathTests {
    static let greekGift = """
    [Event "Greek gift"]
    [White "W"]
    [Black "B"]
    [Result "*"]

    1. e4 e6 2. d4 d5 3. Nc3 Nf6 4. e5 Nfd7 5. Nf3 Be7 6. Bd3 O-O 7. Bxh7+ Kxh7 8. Ng5+ Kg8 9. Qh5 *
    """

    func run(_ source: String, _ pgn: String) throws -> CQLResult {
        try CQLEngine(source: source).run(pgn: pgn)
    }

    func positions(_ source: String, _ pgn: String = greekGift) throws -> [Int] {
        try run(source, pgn).matches.first?.matchedPositions ?? []
    }

    func comments(_ source: String, _ pgn: String = greekGift) throws -> [String] {
        try run(source, pgn).matches.first?.comments.map(\.text) ?? []
    }

    @Test func parsing() throws {
        let program = try Parser.parse("cql() ⊢◎♕ title \"q\" nestban ♗×♟h7 check (――up 1 ♕ ――right 1 ♕)+ ――up 1 ♕ ? ~T―― {2,} {x=1+2}")
        guard case .compound(let body) = program.body, case .path(let path) = body.first else {
            Issue.record("not a path")
            return
        }
        #expect(body.count == 1)
        #expect(path.title == "q" && path.nestBan && path.focus != nil)
        #expect(path.constituents.count == 6)
        guard case .repetition(let chain, 1, nil) = path.constituents[2] else { Issue.record("chain+"); return }
        #expect(chain.count == 2)
        guard case .repetition(_, 0, 1) = path.constituents[3] else { Issue.record("?"); return }
        guard case .repetition(let group, 2, nil) = path.constituents[4], case .move(let dash) = group.first else {
            Issue.record("{2,}")
            return
        }
        #expect(dash.left == .complement(.variable("T")))
        guard case .filter(.compound) = path.constituents[5] else { Issue.record("braced filter"); return }
    }

    @Test func repetitionGroupsTheLastDashAndItsFilters() throws {
        let program = try Parser.parse("cql() ⊢ ♕♛―― check +")
        guard case .compound(let body) = program.body, case .path(let path) = body.first,
              case .repetition(let group, 1, nil) = path.constituents.first else {
            Issue.record("bad parse")
            return
        }
        #expect(group.count == 2)
        #expect(throws: CQLError.self) { try Parser.parse("cql() ⊢ check +") }
    }

    @Test func blankLineEndsThePath() throws {
        let program = try Parser.parse("cql()\n⊢ ――\n  ――\n\ncheck")
        guard case .compound(let body) = program.body else { return }
        #expect(body.count == 2)
    }

    @Test func greekGift() throws {
        #expect(try positions("cql() 3 == ⊢ ♗×♟h7 check ♚×h7 ♘――g5 check") == [12])
        // Without the check after Ng5 the path still matches; the value is the path length.
        #expect(try comments("cql() x = ⊢ ♗×♟h7 ♚×h7 ――\n\n/// x") == ["3"])
    }

    @Test func longestPathAndRepetitions() throws {
        #expect(try comments("cql() initial {x = ⊢ ―― *} /// x") == ["17"])
        #expect(try comments("cql() initial {x = ⊢ ――{3}} /// x") == ["3"])
        #expect(try comments("cql() initial {x = ⊢ ―― {2,4}} /// x") == ["4"])
        #expect(try comments("cql() initial {x = ⊢ (△―― ▲――)+} /// x") == ["16"])
        #expect(try comments("cql() initial {x = ⊢ firstmatch ―― +} /// x") == ["17"])
        #expect(try positions("cql() ⊢ ―― ―― ――") == Array(0...14))
    }

    @Test func focusSkipsOtherMoves() throws {
        // 3. Qh5 Nf6 4. Qxf7#: the black knight move is skipped.
        #expect(try positions("cql() ⊢◎♕ ――h5 ――f7", SamplePGN.scholarsMate) == [4])
        #expect(try comments("cql() ⊢◎♕ piecepath ――h5 ――f7", SamplePGN.scholarsMate) == ["Qd1-h5-f7"])
        #expect(try comments("cql() {x = ⊢◎♕ ――h5 ――f7} /// x", SamplePGN.scholarsMate) == ["2"])
    }

    @Test func statusFiltersAndAtomics() throws {
        #expect(try positions("cql() initial ⊢ ―― ―― {pathcount == 2 pathstart:initial}") == [0])
        #expect(try comments("cql() initial {atomic c = 0 ⊢ ―― {c += 1} *} /// c") == ["17"])
        #expect(try positions("cql() initial (⊢ lastposition ――*):terminal") == [0])
        #expect(try comments("cql() initial {⊢ ―― ―― ――} /// pathlastposition:ply") == ["3"])
    }

    @Test func nestban() throws {
        // Without nestban every start position of a check sequence matches.
        #expect(try positions("cql() ⊢ ―― check +") == [12, 14])
        #expect(try positions("cql() ⊢ nestban ―― check +") == [12, 14])
        // The path from 0 contains positions 1 and 2, so the next allowed start is 3.
        #expect(try positions("cql() ⊢ nestban ―― ――") == [0, 3, 6, 9, 12, 15])
    }

    @Test func contextualCastlingInsidePaths() throws {
        let castle = "cql() ⊢ ♖―― {x = from} /// x"
        #expect(try comments(castle, SamplePGN.specialMoves) == ["h1"])
        #expect(try comments("cql() ⊢ ♔―― o-o {x = to} /// x", SamplePGN.specialMoves) == ["g1"])
    }

    static let rookCorners = """
    [Event "Corners"]
    [White "W"]
    [Black "B"]
    [Result "*"]
    [SetUp "1"]
    [FEN "8/8/2k5/8/8/3K4/8/R7 w - - 0 1"]

    1. Ra1h1 Kd6 2. Rh8 Kc6 3. Ra8 Kd6 *
    """

    static let queenStaircase = """
    [Event "Staircase"]
    [White "W"]
    [Black "B"]
    [Result "*"]
    [SetUp "1"]
    [FEN "7k/8/8/8/8/8/8/Q5K1 w - - 0 1"]

    1. Qa2 Kh7 2. Qb2 Kg8 3. Qb3+ Kh8 4. Qc3+ Kg8 5. Qc4+ Kh8 6. Qd4+ Kg8 7. Qd5+ Kh8 8. Qe5+ Kg8 *
    """

    @Test func rookVisitsTheCornersIgnoringOtherMoves() throws {
        let source = """
        cql()
        T∊♖
          ✵⊢◎T a1――h1 ――h8 ――a8
        """
        #expect(try positions(source, Self.rookCorners) == [0])
        // Without ✵ only position 2 matches: the first move of a path must be in
        // focus, so position 1 (Black to move) cannot start it.
        #expect(try positions("cql() T∊♖ ⊢◎T h1――h8 ――a8", Self.rookCorners) == [2])
        // With ✵, rotating by 270° gives a1――h1 ――h8, which also matches at 0.
        #expect(try positions("cql() T∊♖ ✵⊢◎T h1――h8 ――a8", Self.rookCorners) == [0, 2])
    }

    @Test func queenStaircaseOfEightMoves() throws {
        let source = """
        cql()
        ✵⬓ 8≤sort "staircase size"
          ⊢◎♕ "queen staircase" nestban piecepath
            (――up 1 ♕ ――right 1 ♕)+
            ――up 1 ♕ ?
        """
        let result = try run(source, Self.queenStaircase)
        #expect(result.matches.first?.matchedPositions == [0])
        #expect(result.matches.first?.sortValues.first?.value == .number(8))
        #expect(result.matches.first?.comments.map(\.text) == ["queen staircase: Qa1-a2-b2-b3-c3-c4-d4-d5-e5"])
    }
}
