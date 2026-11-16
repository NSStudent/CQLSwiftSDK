import Testing
@testable import CQL

@Suite("Lexer")
struct LexerTests {
    func kinds(_ source: String) throws -> [TokenKind] {
        try Lexer.tokenize(source).map(\.kind).dropLast()
    }

    func designator(_ types: PieceTypeSet, _ squares: SquareSet = .all) -> TokenKind {
        .pieceDesignator(PieceDesignator(pieceTypes: types, squares: squares))
    }

    func sq(_ name: String) -> SquareSet { SquareSet(index: SquareName.index(of: name)!) }

    @Test func headerAndKeywords() throws {
        #expect(try kinds("cql (input hhdbvi.pgn) btm stalemate") == [
            .identifier("cql"), .leftParen, .identifier("input"), .identifier("hhdbvi"), .dot,
            .identifier("pgn"), .rightParen, .identifier("btm"), .identifier("stalemate"),
        ])
    }

    @Test func asciiAndUnicodePiecesAreEquivalent() throws {
        #expect(try kinds("R") == kinds("♖"))
        #expect(try kinds("[Qq]") == kinds("♕♛"))
        #expect(try kinds("A") == kinds("△"))
        #expect(try kinds("_f1-8") == kinds("□f1-8"))
        #expect(try kinds("[Aa]") == kinds("◭"))
    }

    @Test func pieceDesignatorsWithSquares() throws {
        let rook = PieceTypeSet(CQLPiece(.rook, .white))
        #expect(try kinds("Ra3") == [designator(rook, sq("a3"))])
        #expect(try kinds("a-h3") == [designator(.everything, SquareSet.rank(2))])
        #expect(try kinds("a") == [designator(.black)])
        #expect(try kinds("ab3") == [designator(.black, sq("b3"))])
        #expect(try kinds("[a1,h1,a8,h8]") == [designator(.everything, sq("a1") | sq("h1") | sq("a8") | sq("h8"))])
        #expect(try kinds("A[b-h2,d5]").count == 1)
        #expect(try kinds("▦") == [designator(.everything)])
    }

    @Test func wordsThatStartLikeDesignatorsAreIdentifiers() throws {
        #expect(try kinds("and Kings check e x") == [
            .identifier("and"), .identifier("Kings"), .identifier("check"), .identifier("e"), .identifier("x"),
        ])
    }

    @Test func unicodeOperatorsNormalise() throws {
        #expect(try kinds("Q→k") == kinds("Q->k"))
        #expect(try kinds("Q←k") == kinds("Q<-k"))
        #expect(try kinds("x ≤ 3 ≥ ≠") == kinds("x <= 3 >= !="))
        #expect(try kinds("A ∪ a ∩ _") == kinds("A | a & _"))
        #expect(try kinds("⊢ ◎ ✵ ⬓ ∙") == [
            .identifier("path"), .identifier("focus"), .identifier("flip"), .identifier("flipcolor"), .identifier("currentposition"),
        ])
        #expect(try kinds("♔――♚") == kinds("K--k"))
        #expect(try kinds("×") == kinds("[x]"))
        #expect(try kinds("∊ ∀ ≺ ≻ ≼ ≽") == kinds("[element] [forall] [<] [>] [<=] [>=]"))
    }

    @Test func commentsAndAnnotations() throws {
        let source = """
        check // ignored
        /// "kept"
        //// ignored too
        /* block
           comment */ mate
        """
        #expect(try kinds(source) == [.identifier("check"), .annotation, .string("kept"), .identifier("mate")])
    }

    @Test func castlingAndStrings() throws {
        #expect(try kinds("o-o o-o-o \"a b\" \\n \\2 \\-1") == [
            .identifier("o-o"), .identifier("o-o-o"), .string("a b"), .escapedString("\n"),
            .captureGroup(2), .captureGroupIndex(1),
        ])
    }

    @Test func subscriptBracketsAfterOperands() throws {
        #expect(try kinds("X[1]") == [.identifier("X"), .leftBracket, .integer(1), .rightBracket])
        #expect(try kinds("D[x]") == [.identifier("D"), .leftBracket, .identifier("x"), .rightBracket])
        #expect(try kinds("Q [x] r") == [designator(PieceTypeSet(CQLPiece(.queen, .white))), .capture, designator(PieceTypeSet(CQLPiece(.rook, .black)))])
    }

    @Test func locationsAreTracked() throws {
        let tokens = try Lexer.tokenize("cql()\n  check")
        #expect(tokens[3].location == SourceLocation(line: 2, column: 3))
        #expect(tokens[3].precededBySpace)
    }
}
