# CQLSwiftSDK

A Swift package (SPM) that parses and runs **CQL 6.2** ([Chess Query Language](https://www.gadycosteff.com/cql/)) files against PGN games. It uses [fischer-core](https://github.com/NSStudent/fischer-core) to read PGN and replay games.

## Installation

```swift
.package(url: "https://github.com/NSStudent/CQLSwiftSDK.git", from: "0.2.0")
```

Then add `.product(name: "CQL", package: "CQLSwiftSDK")` to your target's dependencies. Requires Swift 6.0 or later, macOS 13 or iOS 16.

## Products

| Product | Kind | Description |
|---|---|---|
| `CQL` | library | Lexer, parser (AST), interpreter and search engine |
| `cql-swift` | executable | Command-line tool modelled on the reference `cql` program |

## Using the library

```swift
import CQL

let engine = try CQLEngine(source: """
cql(variations)
⬓{wtm not check
  3≤sort "Number of immured pieces"
    I∊♖♘♗♕∩~pin
      not legal I――}
""")
let result = try engine.run(pgn: pgnText)
for match in result.matches {
    print(match.gameNumber, match.matchCount, match.sortValues)
}
print(result.outputPGN)   // matching games, annotated with {CQL} and generated comments
```

### Reading PGN input

Games are read one at a time, so a broken game does not stop the run:

- `run(pgn:)`, `run(pgnData:)` and `run(contentsOf:)` (which reads files incrementally, decoding each line as UTF-8 or Latin-1) skip games that cannot be read and list them in `CQLResult.skippedGames`, with their game number, byte offset and reason. Game numbers keep their position in the input.
- `CQLResult.partiallyReadGames` lists games that were searched only up to an illegal or unreadable move.
- To decide case by case, set `Options.onInvalidGame`: return `.skip` to continue or `.abort` to stop the run with a `CQLError`.

```swift
var options = CQLEngine.Options()
options.onInvalidGame = { error in
    print("skipping \(error)")
    return .skip          // or .abort
}
let result = try CQLEngine(source: source, options: options).run(contentsOf: pgnURL)
```

### Evaluating games without PGN

Games that are already decoded can be tested directly, without producing PGN text:

```swift
let tree = try GameTree(moves: resolvedMoves, startingFEN: nil,
                        tags: ["White": "Tal, Mikhail", "Date": "1960.03.15", "Result": "1-0"])
if let match = try engine.evaluate(game: tree) {
    print(match.matchedPositions)   // positionids (ply numbers on the mainline)
}
```

`GameTree(game:)` accepts a FischerCore `Game`. `GameMatch.annotatedPGN` is only built when it is read.

### Pre-filtering with necessary conditions

`CQLPlan.necessaryConditions(of:)` (or `program.necessaryConditions`) extracts from the top-level conjunction of a program the conditions every matching game must meet, so that an index can discard games before CQL runs:

- position conditions that must hold together at one position: piece counts per designator (`Pd4` → at least one, `not P[c2-7]` → none, `4 ≤ ♙ < 7` → 4…6), side to move, `fen` placements;
- game conditions: tag substrings (`player "Tal"`), Elo ranges, year range, result, game number range.

`isExact` tells whether the conditions are equivalent to the program; `untranslated` lists the parts that are not. The AST (`Filter`) is public; `subfilters` and `contains(where:)` walk it.

```swift
let conditions = try Parser.parse("cql() Pd4 and not P[c2-7,e2-7] and not [Pp][c2-7,d5-7]").necessaryConditions
conditions.isExact                     // true
conditions.position.pieces[0].count    // 1...64
```

### Threads

A `CQLEngine` (and its `Evaluator`) is not thread-safe: use one engine per thread. A `GameTree` caches legal moves lazily, so do not evaluate the same tree from several threads at once. There is no other shared mutable state, so engines on different threads run independently.

The API is layered:

- `Lexer.tokenize(_:)`: tokens, with Unicode spellings normalised to their ASCII equivalents (`→`≡`->`, `――`≡`--`, `♔`≡`K`, …).
- `Parser.parse(_:) -> CQLProgram`: the header (`CQLHeader`) and the body (`Filter`, an `indirect enum` AST).
- `GameTree.read(pgn:)`: the position tree of each game, with variations, `positionid` and piece identities, plus the games that could not be read. `GameTree.games(fromPGN:)` throws on the first unreadable game instead.
- `Evaluator`: evaluates filters at a position.
- `CQLEngine`: the main loop (matchcount, gamenumber, sort, PGN output).

## Command line

```bash
swift run cql-swift -i games.pgn search.cql          # writes search-out.pgn
swift run cql-swift -i games.pgn -stdout -cql 'mate ♘==2'
swift run cql-swift -parse search.cql                # prints the AST
```

Options: `-i/-input`, `-o/-output`, `-cql`, `-variations`, `-mainline`, `-g/-gamenumber`, `-matchcount`, `-silent`, `-quiet`, `-matchstring`, `-noheader`, `-strict`, `-parse`, `-stdout`.

Unreadable games are skipped with a warning on standard error; `-strict` stops at the first one instead.

## Implementation status

**Supported**

- Lexer for both ASCII and Unicode: piece designators (`[Qq]a-h2`, `♖♗a4`, `A[b-h2,d5]`, `▦`, `[]`), `//`, `/* */`, `///` and `////` comments, strings, `\n` and `\1`, `o-o` and `o-o-o`.
- CQL 6.2 precedence, including the type-directed parsing the documented examples require (`#♖ + #♛`, `ascii 65 + "C"`, `find all check > 20`).
- Header: `input`, `output`, `matchcount`, `sort matchcount`, `gamenumber`, `result`, `silent`, `quiet`, `variations` and `matchstring`.
- Logic and control flow: `and`, `or`, `not`, `if/else`, `while` (including the `~~` form), `loop`, `assert`, `{}` compounds, `true` and `false`.
- Variables: numeric, set, string, position and piece variables; `=`, `=?`, `+=` and the other compound assignments; `persistent`; `dictionary` and `local dictionary`; `isbound`, `isunbound` and `unbind`; user-defined functions (macro-expanded, with arguments passed by reference).
- Iteration: `square [all] x in`, `piece [all] x in`, `x∊S`, `◭x∊S`, `∀x∊S`, dictionary iteration and the `◭x=S` piece assignment.
- Sets and numbers: `| & ~ ∪ ∩`, `# + - * / %`, chained (right-associative) relational operators, `in`, `abs`, `sqrt`, `min`, `max`.
- Chess: `check`, `mate`, `stalemate`, `wtm`, `btm`, `sidetomove`, `→`, `←` (including chains such as `♖→▲→♚`), `attacks`, `attackedby`, `pin`, `ray`, `xray`, `between`, direction filters with ranges, `light`, `dark`, `rank`, `file`, `makesquare`, `type`, `typename`, `piecename`, `pieceid`, `colortype`, `power`, `passedpawns`, `doubledpawns`, `isolatedpawns`, `connectedpawns`, `fen` and `fen "…"` (with wildcards).
- Moves: `――` and `×` with origin, destination, `=promotion` and a `(…)` target list; `legal`, `pseudolegal`, `currentmove` and `countmoves`; `from`, `to`, `o-o`, `o-o-o`, `castle`, `enpassant`, `enpassantsquare`, `primary`, `secondary` and contextual castling.
- Game tree: `parent`, `child[(i)]`, `position`, `positionid`, `ply`, `movenumber`, `depth`, `initial`, `initialposition`, `terminal`, `mainline`, `variation`, `virtualmainline`, `try`, `:`, `∙`, `≺ ≻ ≼ ≽`, `lca`, `distance`, `ancestor`, `descendant`, `find` (`all`, range, `<--`) and `echo`.
- Transforms: `flip`/`✵`, `flipcolor`/`⬓`, `reversecolor`, `fliphorizontal`, `flipvertical`, `rotate90`, `shift`, `shifthorizontal`, `shiftvertical`, `count` and `notransform`.
- Strings: `+`, `[i]`, `[m:n]`, subscript assignment, `~~` with capture groups, `str`, `ascii`, `int`, `indexof`, `lowercase`, `uppercase`, `readfile`.
- Game data: `player`, `event`, `site`, `date`, `eventdate`, `eco`, `tag`, `elo`, `year`, `result`, `gamenumber`, `lastgamenumber`, implicit search (`player "Tal"`), `originalcomment` and `hascomment` (including NAGs).
- Paths: `⊢`/`path` with `――` and `×` constituents, filter constituents, `( … )` chains and `* + ? {n} {n,} {,n} {m,n}` repetitions. Parameters: `◎`/`focus` (also `capture`; out-of-focus moves are skipped), `primary`, `max`, `firstmatch`, `lastposition`, `nestban`, `keepallbest`, `title`, `verbose`, `piecepath` and `quiet`. The longest path is chosen, or the one that maximises `max`. A blank line ends the filter. Also `atomic`, the path status filters (`pathstart`, `pathlastposition`, `pathcount`, `pathcountunfocused`) and contextual castling inside paths.
- Problem-quality mates and stalemates: `puremate`, `modelmate`, `idealmate`, `purestalemate`, `modelstalemate` and `idealstalemate`, using the Encyclopedia of Chess Problems definitions adopted by CQL (guards computed with the king removed, necessary pins and necessary double checks). They return the set of participating pieces.
- `consecutivemoves [quiet] [range] (x y)`, which annotates the paired moves.
- Output: `comment` and `///` with smart comments (discarded when the enclosing filter fails), `message`, `sort` (`min`, documentation strings, several keys), `settag`, `removecomment`.

**Not yet implemented**

- `line` (deprecated, superseded by `⊢`), `move` (deprecated), `similarposition`, `hhdb`, `writefile`.
- `rotate45`.
- Automatic comments from `find` and `echo`. The comments produced by `⊢` (`verbose`, `piecepath`, `title`) use this package's own format (`queen staircase: Qa1-a2-b2`), because the documentation does not specify the exact text.
- Null moves (`--` in PGN): fischer-core cannot read them yet.

All 32 example files from the official documentation parse and run.

If a file uses a filter that is not implemented yet, the parser rejects it with an explicit error (`the 'move' filter is not supported yet`) instead of misinterpreting it.

## Language reference

`Docs/Reference/` contains implementation notes condensed from the official CQL 6.2 documentation. Ambiguities in the specification are marked with ⚠️, each with the interpretation this package uses:

- `01-language-core.md`: lexical structure, types, precedence, variables, operators, position filters and game metadata.
- `02-gametree-moves-output.md`: execution model, game tree, moves, `⊢`, transforms and output.

## Development

```bash
swift build
swift test
```

`CQLEngine` runs each search on its own thread with a 512 MB stack. Path matching is recursive, and secondary threads often have stacks of only 512 KB. If you call `Evaluator` directly on long games, run it on a thread with a large stack as well.

## License

MIT. See [LICENSE](LICENSE).
