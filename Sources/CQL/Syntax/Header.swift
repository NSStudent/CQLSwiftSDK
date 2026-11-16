/// The parameters in a CQL header: `cql ( ... )`.
public struct CQLHeader: Hashable, Sendable {
    public var input: String?
    public var output: String?
    public var matchCount: ClosedRange<Int>?
    public var sortByMatchCount = false
    public var gameNumber: ClosedRange<Int>?
    public var result: String?
    public var silent = false
    public var quiet = false
    public var variations = false
    public var matchString: String?
    /// Parameters that were recognised syntactically but are not interpreted.
    public var unsupported: [String] = []

    public init() {}
}

extension Parser {
    /// Parses `cql ( parameters )`. The `cql` keyword is optional when the
    /// source is a bare body (as used by `-cql` on the command line).
    mutating func parseHeader() throws(CQLError) -> CQLHeader {
        var header = CQLHeader()
        guard current.identifier == "cql" else { return header }
        advance()
        try expect(.leftParen, "after 'cql'")
        while current.kind != .rightParen {
            let location = current.location
            guard let name = current.identifier else {
                throw CQLError(.parsing, "expected a CQL parameter, found '\(current.text)'", at: location)
            }
            advance()
            switch name {
            case "input": header.input = try parseFileName()
            case "output": header.output = try parseFileName()
            case "matchcount": header.matchCount = try parseRange()
            case "gamenumber": header.gameNumber = try parseRange()
            case "result": header.result = try parseResultText()
            case "silent": header.silent = true
            case "quiet": header.quiet = true
            case "variations": header.variations = true
            case "matchstring":
                guard case .string(let text) = current.kind else {
                    throw CQLError(.parsing, "matchstring expects a quoted string", at: current.location)
                }
                header.matchString = text
                advance()
            case "sort":
                guard current.identifier == "matchcount" else {
                    throw CQLError(.parsing, "expected 'matchcount' after 'sort' in the CQL header", at: current.location)
                }
                advance()
                header.sortByMatchCount = true
                header.matchCount = try parseOptionalRange() ?? 1...Int.max
            default:
                throw CQLError(.parsing, "unknown CQL parameter '\(name)'", at: location)
            }
        }
        advance()
        return header
    }

    /// A file name: a quoted string or a run of adjacent tokens such as `foo-bar.pgn`.
    mutating func parseFileName() throws(CQLError) -> String {
        if case .string(let text) = current.kind {
            advance()
            return text
        }
        let start = current
        guard start.kind != .rightParen, start.kind != .endOfFile else {
            throw CQLError(.parsing, "expected a file name", at: start.location)
        }
        var name = start.text
        advance()
        while !current.precededBySpace, current.kind != .rightParen, current.kind != .endOfFile {
            name += current.text
            advance()
        }
        return name
    }

    mutating func parseResultText() throws(CQLError) -> String {
        let location = current.location
        var text = ""
        repeat {
            text += current.text
            advance()
        } while !current.precededBySpace && current.kind != .rightParen && current.kind != .endOfFile
        guard ["1-0", "0-1", "1/2-1/2"].contains(text) else {
            throw CQLError(.parsing, "invalid result '\(text)'", at: location)
        }
        return text
    }

    /// One or two integers.
    mutating func parseRange() throws(CQLError) -> ClosedRange<Int> {
        guard let range = try parseOptionalRange() else {
            throw CQLError(.parsing, "expected a range (one or two integers)", at: current.location)
        }
        return range
    }

    mutating func parseOptionalRange() throws(CQLError) -> ClosedRange<Int>? {
        guard let low = integerLiteral() else { return nil }
        advance()
        if let high = integerLiteral() {
            advance()
            guard low <= high else { throw CQLError(.parsing, "empty range \(low) \(high)", at: current.location) }
            return low...high
        }
        return low...low
    }

    /// The value of the current token if it is an integer (optionally negative).
    func integerLiteral() -> Int? {
        if case .integer(let value) = current.kind { return value }
        return nil
    }
}
