import CQL
import Foundation

/// Minimal command line front-end, modelled on the reference `cql` program:
///
///     cql-swift [-i input.pgn] [-o output.pgn] [-variations|-mainline] [-g lo [hi]]
///               [-matchcount lo [hi]] [-silent] [-quiet] [-parse] [-cql "filters"] [file.cql]
struct CommandLine {
    var cqlFile: String?
    var inlineFilters: [String] = []
    var input: String?
    var output: String?
    var options = CQLEngine.Options()
    var parseOnly = false
    var printToStdout = false

    static func usage() -> String {
        """
        usage: cql-swift [options] [file.cql]
          -i, -input FILE        PGN input (overrides the CQL header)
          -o, -output FILE       PGN output (default: <file>-out.pgn)
          -cql "FILTERS"         filters to prepend to the body (may repeat)
          -variations            search variations
          -mainline              search the mainline only
          -g, -gamenumber LO [HI]
          -matchcount LO [HI]
          -silent, -quiet        output comment levels
          -matchstring TEXT      comment for matched positions
          -strict                stop at the first game that cannot be read
                                 (by default such games are skipped with a warning)
          -parse                 only parse the CQL and print the syntax tree
          -stdout                write matching games to standard output
        """
    }

    init(arguments: [String]) throws {
        var index = 0
        func next() throws -> String {
            index += 1
            guard index < arguments.count else { throw CQLError(.input, "missing value for \(arguments[index - 1])") }
            return arguments[index]
        }
        func range() throws -> ClosedRange<Int> {
            guard let low = Int(try next()) else { throw CQLError(.input, "expected a number") }
            if index + 1 < arguments.count, let high = Int(arguments[index + 1]) {
                index += 1
                return low...high
            }
            return low...low
        }
        while index < arguments.count {
            let argument = arguments[index]
            let option = argument.hasPrefix("--") ? String(argument.dropFirst()) : argument
            switch option {
            case "-i", "-input": input = try next()
            case "-o", "-output": output = try next()
            case "-cql": inlineFilters.append(try next())
            case "-variations": options.variations = true
            case "-mainline": options.variations = false
            case "-g", "-gamenumber": options.gameNumber = try range()
            case "-matchcount": options.matchCount = try range()
            case "-silent": options.silent = true
            case "-quiet": options.quiet = true
            case "-matchstring": options.matchString = try next()
            case "-noheader": options.headerComments = false
            case "-strict": options.onInvalidGame = { _ in .abort }
            case "-parse": parseOnly = true
            case "-stdout": printToStdout = true
            case "-h", "-help":
                print(Self.usage())
                exit(0)
            default:
                guard !argument.hasPrefix("-") else { throw CQLError(.input, "unknown option \(argument)") }
                cqlFile = argument
            }
            index += 1
        }
    }
}

func run() throws {
    let command = try CommandLine(arguments: Array(Swift.CommandLine.arguments.dropFirst()))
    var source = ""
    if let file = command.cqlFile {
        let path = file.hasSuffix(".cql") || FileManager.default.fileExists(atPath: file) ? file : file + ".cql"
        source = try String(contentsOfFile: path, encoding: .utf8)
    } else if command.inlineFilters.isEmpty {
        print(CommandLine.usage())
        exit(1)
    } else {
        source = "cql()"
    }
    var program = try Parser.parse(source)
    if !command.inlineFilters.isEmpty {
        let preamble = try Parser.parse("cql() " + command.inlineFilters.joined(separator: " "))
        if case .compound(let extra) = preamble.body, case .compound(let body) = program.body {
            program.body = .compound(extra + body)
        }
        program.functions.merge(preamble.functions) { current, _ in current }
    }
    if command.parseOnly {
        dump(program.body)
        return
    }
    guard let input = command.input ?? program.header.input else {
        throw CQLError(.input, "no input PGN file (use -i or the 'input' header parameter)")
    }
    let engine = try CQLEngine(program: program, options: command.options)
    let start = Date()
    let result = try engine.run(contentsOf: URL(fileURLWithPath: input))
    let elapsed = Date().timeIntervalSince(start)
    for skipped in result.skippedGames {
        FileHandle.standardError.write("cql-swift: warning: skipped \(skipped)\n".data(using: .utf8)!)
    }
    for partial in result.partiallyReadGames {
        FileHandle.standardError.write("cql-swift: warning: partially read \(partial)\n".data(using: .utf8)!)
    }
    let skippedNote = result.skippedGames.isEmpty ? "" : " (\(result.skippedGames.count) unreadable game(s) skipped)"

    if command.printToStdout {
        print(result.outputPGN)
    } else {
        let base = command.cqlFile.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "cqldefault"
        let outputPath = command.output ?? program.header.output ?? "\(base)-out.pgn"
        try result.outputPGN.write(toFile: outputPath, atomically: true, encoding: .utf8)
        FileHandle.standardError.write("\(result.matches.count) matching game(s) of \(result.gamesExamined)\(skippedNote) written to \(outputPath) in \(String(format: "%.2f", elapsed))s\n".data(using: .utf8)!)
    }
    for (name, value) in result.persistentVariables {
        print("\(name): \(value)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write("cql-swift: \(error)\n".data(using: .utf8)!)
    exit(1)
}
