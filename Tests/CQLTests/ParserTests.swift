import Testing
@testable import CQL

@Suite("Parser")
struct ParserTests {
    func body(_ source: String) throws -> [Filter] {
        let program = try Parser.parse("cql() " + source)
        guard case .compound(let filters) = program.body else { return [] }
        return filters
    }

    func one(_ source: String) throws -> Filter {
        let filters = try body(source)
        #expect(filters.count == 1, "expected one filter in \(source), got \(filters)")
        return filters[0]
    }

    func piece(_ text: String) -> Filter {
        guard case .pieceDesignator(let designator) = try! Lexer.tokenize(text)[0].kind else { fatalError() }
        return .pieceDesignator(designator)
    }

    @Test func header() throws {
        let program = try Parser.parse("cql(input hhdbvi.pgn output \"my out.pgn\" variations matchcount 2 5 result 1-0) check")
        #expect(program.header.input == "hhdbvi.pgn")
        #expect(program.header.output == "my out.pgn")
        #expect(program.header.variations)
        #expect(program.header.matchCount == 2...5)
        #expect(program.header.result == "1-0")
    }

    @Test func juxtapositionMakesSeparateFilters() throws {
        #expect(try body("btm stalemate ♜≥2").count == 3)
        guard case .call("str", let arguments) = try one("str(♖a3 or ♘b2 check or stalemate)") else { Issue.record("not a call"); return }
        #expect(arguments.count == 2)
        #expect(throws: CQLError.self) { try Parser.parse("cql() (♖a3 check)") }
    }

    @Test func arithmeticPrecedence() throws {
        // 2+3*4<4/2+1 ≡ (2+(3*4)) < ((4/2)+1)
        #expect(try one("2+3*4<4/2+1") == .binary(.less,
            .binary(.add, .number(2), .binary(.multiply, .number(3), .number(4))),
            .binary(.add, .binary(.divide, .number(4), .number(2)), .number(1))))
    }

    @Test func logicalPrecedence() throws {
        // check or not mate and Q or stalemate ≡ check or ((not mate) and Q) or stalemate
        #expect(try one("check or not mate and Q or stalemate") == .binary(.or,
            .binary(.or, .keyword("check"), .binary(.and, .not(.keyword("mate")), piece("Q"))),
            .keyword("stalemate")))
    }

    @Test func setPrecedence() throws {
        // A | ~B&Q | q ≡ A | ((~B)&Q) | q
        #expect(try one("A | ~B&Q | q") == .binary(.union,
            .binary(.union, piece("A"), .binary(.intersection, .complement(piece("B")), piece("Q"))),
            piece("q")))
    }

    @Test func prefixArgumentLevels() throws {
        #expect(try one("rank x & y") == .prefix("rank", .binary(.intersection, .variable("x"), .variable("y"))))
        #expect(try one("up R|P") == .binary(.union, .direction("up", range: nil, piece("R")), piece("P")))
        #expect(try one("sqrt 4 + 8<9 + 5") == .binary(.less,
            .prefix("sqrt", .binary(.add, .number(4), .number(8))),
            .binary(.add, .number(9), .number(5))))
        #expect(try one("#♖ + #♛") == .binary(.add, .cardinality(piece("R")), .cardinality(piece("q"))))
        #expect(try one("# Q|K") == .cardinality(.binary(.union, piece("Q"), piece("K"))))
        #expect(try one("ascii 65 + \"C\"") == .binary(.add, .prefix("ascii", .number(65)), .string("C")))
        #expect(try one("up 1 3 d4") == .direction("up", range: 1...3, piece("d4")))
        #expect(try one("up -2 d4") == .direction("up", range: -2 ... -2, piece("d4")))
    }

    @Test func relationalIsRightAssociativeAndCountsSets() throws {
        #expect(try one("4 ≤ ♙<7") == .binary(.lessEqual, .number(4), .binary(.less, piece("P"), .number(7))))
        #expect(try one("□←♚>#□←♔") == .binary(.greater,
            .attackChain([piece("_"), piece("k")], reversed: true),
            .cardinality(.attackChain([piece("_"), piece("K")], reversed: true))))
    }

    @Test func arrowChains() throws {
        #expect(try one("♖→▲→♚") == .attackChain([piece("R"), piece("a"), piece("k")], reversed: false))
        #expect(try one("A attacks k | n") == .binary(.union, .attackChain([piece("A"), piece("k")], reversed: false), piece("n")))
    }

    @Test func colonBindsTightest() throws {
        #expect(try one("parent:check") == .at(.keyword("parent"), .keyword("check")))
        #expect(try one("position 0 : ply") == .at(.position(.number(0)), .keyword("ply")))
    }

    @Test func dashForms() throws {
        #expect(try one("e2――e4") == .dash(DashFilter(left: piece("e2"), right: piece("e4")), source: .game))
        #expect(try one("♙――d8=♕") == .dash(DashFilter(left: piece("P"), right: piece("d8"),
                                                        promotion: PieceTypeSet(CQLPiece(.queen, .white))), source: .game))
        #expect(try one("♗×h7(check)") == .dash(DashFilter(left: piece("B"), right: piece("h7"), isCapture: true,
                                                           targets: [.keyword("check")]), source: .game))
        #expect(try body("――d4 mate").count == 2)
        #expect(try one("x=♘――(to)") == .assign("x", .assign,
            .dash(DashFilter(left: piece("N"), targets: [.keyword("to")]), source: .game)))
        #expect(try one("legal ♔――a-h4") == .dash(DashFilter(left: piece("K"), right: piece("a-h4")), source: .legal))
    }

    @Test func iterationAndVariables() throws {
        let filter = try one("square x in A rank x<3")
        #expect(filter == .iterate(isPiece: false, all: false, variable: "x", domain: piece("A"),
                                   body: .binary(.less, .prefix("rank", .variable("x")), .number(3))))
        #expect(try body("square x in ▲ ♕→x ♘→x").count == 2)
        #expect(try one("x∊a-h8 ♖→x") == .iterate(isPiece: false, all: false, variable: "x", domain: piece("a-h8"),
                                                    body: .attackChain([piece("R"), .variable("x")], reversed: false)))
        guard case .iterate(true, false, "y", _, .find) = try one("◭y∊♙a-h2 find y――=♖") else { Issue.record("piece iteration"); return }
        guard case .iterate(false, true, "x", _, _) = try one("∀x∊□←♚ 1==△→x") else { Issue.record("forall"); return }
    }

    @Test func findCapturesEverything() throws {
        #expect(try one("find {――=♗} or check") == .find(quiet: false, mode: .first, backward: false,
            .binary(.or, .compound([.dash(DashFilter(promotion: PieceTypeSet(CQLPiece(.bishop, .white))), source: .game)]),
                    .keyword("check"))))
    }

    @Test func transformsTakeOneFilter() throws {
        #expect(try body("⬓ check ♖a1").count == 2)
        #expect(try one("flipcolor {check ♖a1}") == .transform(.flipcolor, count: false, .compound([.keyword("check"), piece("Ra1")])))
    }

    @Test func implicitSearchAndAnnotations() throws {
        #expect(try one("player \"Kasparov\"") == .binary(.in, .string("Kasparov"), .tagValue(.player(nil))))
        let filters = try body("x = 3\n/// \"x is \" x\ncheck")
        #expect(filters.count == 3)
        #expect(filters[1] == .comment([.string("x is "), .variable("x")]))
    }

    @Test func functionsAndStrings() throws {
        let program = try Parser.parse("cql() function f(u v) { u + v } f(1 2) == 3 \"mate\"[1:-1] == \"at\"")
        #expect(program.functions["f"]?.parameters == ["u", "v"])
        guard case .compound(let filters) = program.body else { return }
        #expect(filters.count == 2)
        #expect(filters[1] == .binary(.equal, .subscript(.string("mate"), .number(1), .number(-1), isSlice: true), .string("at")))
    }

    @Test func errorsHaveLocations() {
        #expect(throws: CQLError.self) { try Parser.parse("cql() (check mate)") }
        do {
            _ = try Parser.parse("cql()\n  check )")
        } catch {
            #expect(error.location?.line == 2)
        }
    }
}

