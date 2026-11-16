# CQL 6.2 Reference — Part 2: Game Tree, Moves, Paths, Transforms, Output

Implementation-oriented condensation of the CQL 6.2 docs. Source pages: cqlfilestructureandoperation, cqlparameters,
options, usage, commandlineprogramming, gametree, currentposition, currentmove, dash, move, path, focus,
pathstatusfilters, line, find, echo, sort, transform, transformformal, flip*, shift*, rotate*, comment, message,
originalcomment, settag, readfile, writefile, hhdb, deprecated, plus examples.

Part 1 (language core: lexing, piece designators, variables, operators, set/attack filters, tag filters, strings,
ranges, relational ops, compound filters) is referenced as **[P1]**.

Conventions

- **Types** of filter values: `logical` (no value, just match/no-match), `set` (square set; always has a value, empty
  set ⇒ no match), `number`, `string`, `position`. A non-set filter that does not match has *no value*.
- "matches" = matches the current position. Unless stated, if any argument fails to match, the filter fails.
- `range` = one or two integers `lo [hi]`, inclusive; `hi` defaults to `lo` [P1]. Numeric variables allowed in
  ranges inside the body, *not* in the header or on the command line.
- ⚠️ AMBIGUOUS marks spots where the docs are unclear/contradictory; a recommended interpretation is given when
  reasonable. All ambiguities are collected in §8.

---

## 1. Execution model

### 1.1 CQL file structure

```
cql ( <header-parameter>* )  <body-filter>*
```

- Literal word `cql`, then header in parentheses (may be empty: `cql()`), then the **body**: a sequence of filters
  treated as one implicit compound filter (all must match).
- Default CQL file (used when no .cql file is given but `-i` is): `cql().` — body is `.` (▦, all squares; a set
  filter that always matches) ⇒ every position matches.

### 1.2 Header parameters

| Parameter | Syntax | Semantics |
|---|---|---|
| input | `input FILE` | PGN file to read. Must end in `.pgn`. May be quoted (`"a b.pgn"`). Overridden by `-i/-input`. |
| output | `output FILE` | PGN output file, must end in `.pgn`. Overridden by `-o/-output`. Default: `<cqlbasename>-out.pgn` (no path, no `.cql`); with no CQL file: `cqldefault-out.pgn`. |
| matchcount | `matchcount RANGE` | Game is output only if its matchcount (number of matched positions) ∈ RANGE. Range may include 0 (`matchcount 0` = negation of the file). Default rule without it: matchcount > 0. |
| sort matchcount | `sort matchcount RANGE` | Same selection as `matchcount RANGE`, plus output sorted by matchcount descending. Header only; no doc string; no `min`. |
| gamenumber | `gamenumber RANGE` | Only examine games whose 1-based game number ∈ RANGE (also `-gamenumber/-g`). Example `gamenumber 100 1000`. |
| result | `result 1-0` / `result 0-1` / `result 1/2-1/2` | Only games with this result. (Also a body filter, see [P1].) |
| silent | `silent` | No comments of any kind inserted into the output (user, auto, header, "CQL"). |
| quiet | `quiet` | Suppress CQL auto-generated comments (find/echo/⊢/line/sort/consecutivemoves); keep user comments and header comments. Whether the per-match "CQL" string survives is ⚠️ AMBIGUOUS (§6.3). |
| variations | `variations` | Visit/consider variation positions too (main loop *and* tree-walking filters: ――, move, line, ⊢, find, echo, …). Overridden by `-mainline`; also settable by `-variations`. |
| matchstring | `matchstring "STRING"` | Text of the comment inserted at each matched position (default `CQL`). Empty string ⇒ nothing inserted. |

Notes
- Parameter order is free (examples: `cql(input x.pgn variations result 1-0 quiet)`).
- Command-line options override the header (including quiet/silent level).
- `persistent`, `readfile`, `writefile`, `dictionary` force single-threaded execution (only relevant if the
  implementation parallelises games; semantics must be as if games are processed sequentially in order).

### 1.3 Main loop

```
parse header + command line → input, output, flags
body := preamble(-cql/-fen/-similarposition filters) ++ fileBody   // preamble is one compound filter, prepended
body := wrap(body, commandLineTransforms)                           // e.g. -flipcolor ⇒ ⬓{body}
for each game g in input (gamenumber ∈ range, metadata options pass):
    tree := parse PGN; if !variations: prune to mainline (restore on output)
    matchcount := 0
    for each position P of tree in PGN order (pre-order: a move, then its variations' subtrees in order… see ⚠️):
        currentPosition := P
        if evaluate(body) matches:   matchcount += 1; mark P with matchstring comment
        else: discard smart comments generated during this evaluation (§6.2)
    if (matchcountRange given ? matchcount ∈ range : matchcount > 0): output g with annotations
after all games: sort output games by sort keys (§4.9), write file; print persistent vars [P1]
```

- Every filter is evaluated relative to the **current position**. Some filters temporarily change it and restore it:
  `⊢/path`, `――` target, `find`, `echo`, `:`, `line`, `move ... comment`.
- ⚠️ AMBIGUOUS: exact visiting order with variations is only described as "the order they occur in the PGN file".
  Recommended: depth-first pre-order following PGN text order (for `1. e4 (1. d4 d5) e5`: start, e4-pos, d4-pos, d5-pos, e5-pos).

### 1.4 Mainline vs variations

- Default (variations not set): CQL conceptually prunes all non-mainline positions. Consequences: every position is
  mainline; `mainline` always true, `variation` always false; each position has ≤ 1 child; `positionid == ply`;
  `X<Y` ⟺ `X≺Y`; `child` ≡ `child(0)`; at most one move from any position.
- With `variations`: the full tree is visible to the main loop and to every tree-walking filter (――, ×, move, line, ⊢,
  find, echo, child(i), terminal, countmoves …). `legal`/`pseudolegal` generate moves and are unaffected.
- `-virtualmainline` ≡ `-cql virtualmainline` + sets variations, but (unlike -variations/-mainline) does **not**
  apply recursively inside move/find/line/echo — it just adds a top-level filter.

### 1.5 Game output

Output game = original game (including pruned variations) + annotations:
1. Header comments (before first move): game number in the input, value of each sort filter (with its doc string).
   Suppressed by `-noheader`.
2. matchstring (default `CQL`) at each matched position.
3. CQL-generated comments from find, echo, ⊢, line, sort, consecutivemoves (suppressed by `quiet` header/option, or
   by a per-filter `quiet` keyword).
4. User comments from `comment` / `///`.
5. Tag changes from `settag`; original comments removed by `removecomment`.
- Comment placement: a comment generated "at position P" is attached after the move leading to P (PGN comments belong
  to moves); for the initial position it goes before the first move.
- `silent` removes 1–4 entirely.

### 1.6 Command-line options that affect semantics (brief)

Options follow the program name, precede the .cql file; single or double hyphen. They override header settings.

| Option | Effect |
|---|---|
| `-i/-input F`, `-o/-output F` | input / output files (`.cql` extension of the CQL file may be omitted). `-vi` = `-input hhdbvi.pgn`. |
| `-g/-gamenumber lo [hi]` | game-number range. |
| `-matchcount lo [hi]` | as header `matchcount`. |
| `-variations`, `-mainline`, `-virtualmainline` | see §1.4. |
| `-cql "filters"` (repeatable), `-fen FEN` | command-line filters collected into one compound **preamble** prepended to the body. `-fen` matches positions with that FEN board. `///` not allowed in `-cql`. Unicode not supported on the command line. |
| `-flip -flipcolor -reversecolor -shift …` (any transform name) | applies that transform to **all subsequent** filters (preamble and body), i.e. wraps them. |
| `-silent`, `-quiet`, `-matchstring S`, `-noheader`, `-alwayscomment` (disable smart comments) | output control. |
| `-noremovecomment`, `-nosettag` | make `removecomment` / `settag` no-ops. |
| `-similarposition [nosort] [notransform] F.pgn` | prepend `similarposition` filter (§4.10). |
| `-player/-white/-black/-event/-site NAME`, `-year lo [hi]`, `-result R` | metadata pre-filters (implicit search on tags) [P1]. |
| `-assign VAR VALUE` | pre-assign variable VAR to string VALUE (number if numeric). |
| `-hhdb KEY [arg]` | hhdb filter from the command line (§6.10). |
| `-threads N`, `-s/-singlethreaded`, `-lineincrement N`, `-showmatches`, `-gui`, `-html`, `-u`, `-a`, `-help`, `-version`, `-parse`, `-nolinearize`, `-outputbuffer N` | non-semantic / tooling / unsupported. |

### 1.7 Input assumptions

- Export-format PGN; no illegal moves; null moves (`--`) allowed. Nested `{}` comments are flattened. Multiple
  comments on one move (or before move 1) are **not supported**. Non-ASCII in PGN typically ignored.

---

## 2. Game tree model

### 2.1 Data model (what the evaluator needs per position node)

```
Position node:
  board, sideToMove, castling/ep state (from PGN replay)
  parent: Node?            // nil for initial position
  children: [Node]         // index i = move index; 0 = primary
  moveFromParent: Move?    // the "current move" of this node
  childIndex: Int          // index among parent's children (0 ⇒ primary move)
  ply: Int                 // 0 for initial; parent.ply + 1
  depth: Int               // variation depth: parent.depth + (childIndex > 0 ? 1 : 0)
  positionId: Int          // unique per game; see below
  moveNumber: Int          // fullmove number of the side to move (see ⚠️)
  originalComment: String?, nags: [Int]
  isVirtualMainline: Bool
```

Definitions
- **initial position**: unique node without parent. **terminal**: no children.
- **primary move** from P: first move from P in the PGN (index 0); others are **secondary** (variations).
- **ply**: number of moves from the initial position.
- **depth**: number of secondary moves on the path from the root. depth 0 ⇔ **mainline**; >0 ⇔ **variation**.
- **positionid**: unique int; mainline positions have `positionid == ply`; for any positions, ancestor ⇒ smaller id.
  ⚠️ AMBIGUOUS: numbering of variation positions not specified. Recommended: number mainline 0..N first, then
  variation nodes in PGN pre-order starting at N+1 (consistent with the doc example "move 5(wtm)[47]" for a variation
  node in a study). Without variations, `positionid == ply` always.
- **movenumber**: per doc example, the position after `4.Ka1` (btm) has move number 4 and the position after
  `4...Ka8` (wtm) has 5 ⇒ the PGN fullmove number of the next move to be played (FEN fullmove counter).
  ⚠️ AMBIGUOUS for games starting from a FEN: presumably the FEN fullmove number.
- **virtual mainline** (rules): initial is VM; all children of a btm VM position are VM; only the primary child of a
  wtm VM position is VM. I.e. VM iff every branch on the path was initiated by Black.
- **LCA(x,y)**: deepest (max ply) common *generalized* ancestor (ancestor-or-self). Always exists and is unique.
- **ancestor**: X≺Y iff Y is reachable from X by a *nonempty* sequence of moves.
- **current move** of a position = the move leading to it (moveFromParent). A move is identified with its tail position.

### 2.2 Game-tree filter table

Notation: `i` numeric filter; `x,y` position filters. Any filter that would return a nonexistent position fails.

| Filter (ASCII / Unicode) | Args | Type | Semantics |
|---|---|---|---|
| `currentposition` / `∙` | – | position | current position. Always matches. |
| `initial` | – | logical | current position is the initial position. |
| `initialposition` | – | position | the initial position (≡ `position 0`). Always matches. |
| `position i` | number (parsed at "just lower than +" precedence: `position ply+1` = `position (ply+1)`) | position | position whose positionid == i; fails if none. |
| `positionid` | – | number | id of current position. |
| `ply` | – | number | ply of current position (initial = 0). |
| `movenumber` | – | number | move number (see §2.1). |
| `depth` | – | number | variation depth (0 for mainline). `variation` ≡ `depth>0`. |
| `mainline` | – | logical | depth == 0. Always true without variations. |
| `variation` | – | logical | depth > 0. Always false without variations. (≠ header param `variations`.) |
| `virtualmainline` | – | logical | current position is a virtual mainline position. |
| `terminal` | – | logical | no children (≡ `not child`). With variations: end of each line is terminal. |
| `parent` | – | position | parent; fails at initial position. |
| `child` | – | position | primary child (≡ `child(0)`); fails if terminal. |
| `child(i)` | number in parens | position | child with move index i; fails if no such child. (Number of children: `countmoves ――`.) |
| `lca(x y)` | 2 positions, parens, lowest-precedence args | position | latest common ancestor. |
| `distance(x y)` | 2 positions | number | `(x.ply − L.ply) + (y.ply − L.ply)` with L = lca; 0 if x == y. |
| `x ≺ y` / `x [<] y` | positions | position (value = left operand when true) | x is a (strict) ancestor of y. `X≺X` false. |
| `x ≼ y` / `[<=]` | positions | position | ancestor or equal. |
| `x ≻ y` / `[>]` | positions | position | x is a strict descendant of y. |
| `x ≽ y` / `[>=]` | positions | position | descendant or equal. |
| `ancestor(x y)` (deprecated → `x≺y`) | | logical | x is ancestor of y. |
| `descendant(x y)` (deprecated → `x≻y`) | | logical | x is descendant of y. `descendant(x y)` ≡ `ancestor(y x)`. |
| `x < y`, `<=`, `>`, `>=`, `==`, `!=` on positions | positions | (relational; value = left operand) | compare **positionids**. `X≺Y ⇒ X<Y`, converse only without variations. |
| `x ∩ y` / `x & y` on positions | positions | set | **positional intersection**: squares where both positions have the same piece type+color (incl. both empty). `source∩target==▦` ⇒ same board. |
| `sidetomove` | – | number | `white` (=1) or `black` (=−1) to move. `sidetomove == x:sidetomove`. |
| `try` | – | logical | defined as `1==find <-- quiet all {btm secondary}`: exactly one White move on the path to here is secondary (top-level White try). |
| `primary` | – | logical | current move was a primary move (move index 0). |
| `secondary` | – | logical | current move was not primary. ⚠️ AMBIGUOUS at initial position (no current move): recommend both false. |
| `gamenumber` | – | number | 1-based number of current game in input. |
| `lastgamenumber` | – | number | game number of last game that will be searched (heuristic, experimental). |

Relational value rules (value = left operand on success; chaining `X≺Y≺Z` returns X) follow [P1].

### 2.3 `:` operator

```
position_filter : filter
```
- Evaluate left (position filter) in the current position → p; if it fails, `:` fails.
- Set current position to p, evaluate right, restore.
- Matches iff right matches at p; value = right's value at p (any type).
- **Highest precedence of all operators**: `x : f * g` ≡ `{x:f} * g`; `source:colortype …` etc. Right side may be any
  filter including another `:` (`position 0 : child : comment("first")`, right-assoc).
- Piece/set variables are just square sets: `s:Piece` evaluates the *set expression* `Piece` (a stored set) — it does
  not follow piece identity. Piece designators on the right are evaluated in p's board.
- `:` changes the current position ⇒ `from`/`to` inside it are not in the scope of an enclosing ―― (§3.6), and in
  `line` it disables linearization.
- Examples: `parent:check`, `child:not check`, `sidetomove==s:sidetomove`, `5==parent:#△`.

### 2.4 Filters that change the current position (temporarily)

`⊢/path`, `――`/`×` target list, `find`, `echo`, `:`, `line`, `move … comment`. Each restores the position after.

---

## 3. Moves

### 3.1 Move model

A PGN move M from head H to tail T has:
- moving piece(s): normally one. **Castling is a move by both king and rook** (6.2 "contextual castling"). White o-o:
  king e1→g1, rook h1→f1.
- from squares, to squares (per moving piece).
- capture square: square of captured piece (= to-square except en passant, where it is the captured pawn's square);
  empty if no capture.
- promotion piece type (if any), en passant flag, castle kind (o-o / o-o-o), null flag.
- **Null move** (`--` in PGN): changes only side to move; treated as a move by the side-to-move king from and to its
  own square (documented for `move`; ⚠️ assume same for ――). The capture filter `×` raises an error ("qmvm cap")
  when it encounters a null move in the PGN (known 6.2 limitation).
- index among siblings (primary/secondary).

### 3.2 Current-move filters (0 arguments, evaluated about the move that led to the current position)

| Filter | Type | Value / meaning |
|---|---|---|
| `from` | set | origin square(s) of the moving piece(s) of the current move. Castling: both king & rook origins (`[e1,h1]`), subject to contextual castling (§3.6). Empty/no-match at initial position. |
| `to` | set | destination square(s); castling both (`[f1,g1]`), contextual. |
| `enpassant` | logical | current move was en passant. |
| `enpassantsquare` | set | square of the pawn captured e.p. by the current move; empty set otherwise. (Note: this is the *captured pawn* square, unlike the FEN ep field.) |
| `nullmove` | logical | current move is a null move. |
| `primary` / `secondary` | logical | §2.2. |
| `o-o` | logical | current move was kingside castling. |
| `o-o-o` | logical | queenside castling. |
| `castle` | logical | any castling. |

These are ordinary filters, so inside a ―― target list (evaluated at the tail) they describe the move just made:
`△――(o-o)`, `――(enpassant)`, `x=♘――(to)`.

### 3.3 ―― (dash) filter — 6.2 move filter

ASCII `--`, Unicode `――` (two U+2015). Capture variant `×` / ASCII `[x]`.

#### Grammar

```
dash      := [LEFT] DASHOP [RIGHT] [ '=' PROMO ] [ '(' TARGET-FILTERS ')' ]
DASHOP    := '――' | '--' | '×' | '[x]'
LEFT      := set filter, written with NO whitespace before DASHOP
RIGHT     := set filter, starting immediately after DASHOP (whitespace after DASHOP ⇒ RIGHT absent)
PROMO     := typename designator: piece designator w/o square part (♖, ♖♗♘, △, [RBN], Q/q …)
             | string literal of ASCII type letters ("RBN") | (in practice) a string-valued variable, e.g. =T
TARGET-FILTERS := filter* (one or more filters, evaluated in the tail; '(' immediately adjacent, no whitespace)
```
- No whitespace is allowed between components (left, operator, right, `=`, `(`) — the ―― is a "generalized piece
  designator". Whitespace after the operator ends the dash: `―― ♗→d3` (in ⊢) = dash with no right + separate filter.
- Missing LEFT or RIGHT ⇒ ▦ (all 64 squares).
- Precedence: documented as "extremely low" for the *operands*: `~♚――` parses as `(~♚)――`; `♖♜――T∪U` has right
  operand `T∪U`; `――~pathstart:T∩□` has right operand `~pathstart:T ∩ □`; `――northeast 1 T`, `――up 1 ♕` work.
  Yet `x=♘――(to)` assigns the dash's value (left operand is `♘`, not `x=♘`), and `◭C = ♖♗♕――(from)`.
  ⚠️ AMBIGUOUS: exact binding power. Recommended: parse LEFT/RIGHT as set expressions including unary/binary set ops
  (`~ ∪ ∩ | &`, `:`, direction/prefix set filters) but excluding assignment, relational, logical operators; the
  no-whitespace adjacency rule disambiguates the boundaries.
- Lexer: `--` must not swallow `-->` (line arrow); `[x]` is a single token.

#### Semantics (matching)

Let H = current position. Candidate moves = moves from H **present in the PGN** (all children if variations set,
only the mainline child otherwise). (For legal/pseudolegal generation see §3.5.)

A move M (with moving pieces p) matches `F――G=X(T…)` iff:
1. Some moving piece p of M has `from(p) ∈ F` **and** `to(p) ∈ G`, with F and G evaluated **in H** (the head).
   - Castling: matches if either (king from∈F ∧ king to∈G) or (rook from∈F ∧ rook to∈G).
   - Right side denotes the *destination square*'s content in H: `――♕a4` = a move to the square of the ♕a4, i.e. its
     capture; `――◭` = captures except e.p. (e.p. destination is empty).
2. `×` variant: M must be a capture (including e.p.). `×` alone = any capture.
3. `=X`: M must be a promotion to a type designated by X (color ignored: `=♖` ≡ `=♜`; `=△` = any promotion).
4. Target list `(T1 … Tn)`: with current position set to M's tail, all Ti must match (implicit compound).
   Inside, `from`/`to` are contextual (§3.6). Comments inside the target are attached at the tail.

The dash **matches H iff some candidate move matches**. "Matching a move" is conceptual; filters match positions.

#### Value

- **With target list**: value = value of the **last target filter** for the **first matching move** in PGN order.
  e.g. `x=♘――(to)` → destination square; `y=△――(from)` → origin square of the first such move.
  ⚠️ AMBIGUOUS: if the last target filter is logical (no value), presumably the dash is logical.
- **Without target**: the dash is a **set filter** whose value is the set of squares of moving pieces (origins) of all
  matching moves (e.g. value of `♕――♞` = squares of white queens that capture a black knight next move;
  `x = ♔――` with white o-o next ⇒ `e1`). Empty set ⇒ no match.
  ⚠️ AMBIGUOUS: the set-of-origins value is stated only on the general "filter" page. Recommended: union over matching
  moves of origin squares of the moving pieces that satisfied rule 1.
- To collect values over *all* matching moves with variations, iterate: `y = z∊△ z――` (all origin squares),
  `z∊▦ ♘――z` (all knight destinations).

#### Examples

```
e2――e4              ♖――                 ――d4 mate   (dash ――d4, then filter mate)
♗×♟h7(check)        ――=♖♗♘  ――="RBN"    ♙――d8=♕     ♟×=♘
△――d4(check)        ♘――(pin through ♖ mate)
♗×h7(check ♚×h7(♘――g5 check))   // nested targets; prefer ⊢ for this
△T = ♕♖――(from)    // piece variable to the major piece that moves next (mainline-only idiom)
```

### 3.4 `currentmove`

```
currentmove DASH        // DASH is any ―― / × filter
```
- Logical: true iff the given dash matches **the current move** (the move that led to the current position).
- ⚠️ AMBIGUOUS: docs don't say where left/right are evaluated; consistent reading: left/right/`=` evaluated in the
  parent (head) position, target filters in the current position (tail). Fails at the initial position.
- Typical: `not currentmove ――=△` (current move not a promotion), `currentmove △――` (last move by White),
  `not currentmove ♖×♟(check)`.

### 3.5 `legal` / `pseudolegal`

```
legal DASH          pseudolegal DASH
```
- DASH must have **no target**, or exactly one target filter that is one of `o-o`, `o-o-o`, `castle`, `enpassant`:
  `legal ――(o-o)`, `legal ♖――`, `pseudolegal ♔――a-h4`.
- Matches iff a legal (resp. pseudolegal: may leave own king in check) move from the current position matches the dash.
  Move need not be in the PGN. Independent of variations.
- In ⊢ a top-level `legal ――…` must be wrapped in braces (`{legal ――b4}`), see §4.3.
- Value: ⚠️ AMBIGUOUS (not documented). Recommended: same as an un-targeted dash (set of origin squares), which makes
  `#legal ♔――` meaningful; `countmoves` is the documented way to count.
- Edge rules (documented for `move legal`, assume same here): in the game's initial position e.p. is never legal;
  castling legality assumes king/rooks have not moved before the initial position. ⚠️ AMBIGUOUS whether FEN castling
  rights are honoured.

### 3.6 Contextual castling (`from`/`to` inside a dash scope)

Scope of a dash:
- Standalone dash: its target filters are in its scope — *except* filters nested in something that changes the
  current position (`:`, `find`, `echo`, …): `――(initialposition:from)` is not in scope.
- In ⊢: a ―― constituent's scope is all following filter constituents up to the next ―― constituent.

Rule: when the current move is castling and `from`/`to` is evaluated in the scope of a dash with left L and right R
(and the ⊢ focus set, if any), a moving piece's origin/destination is included only if origin ∈ L **and**
destination ∈ R (and, under ◎, the piece is focused).

White o-o next:
```
x = ――(from)      // [e1,h1]
x = h1――(from)    // h1      x = ♖――(from)    // h1
x = ――f1(from)    // h1      x = ♖――f1(from)  // h1
x = ♔――(from)     // e1  (doc writes `x= ♔――` — see ⚠️ §8)
⊢ ♖―― check x=from    // h1
⊢ ♔―― x=from          // e1
⊢◎♖ ―― x=from         // h1
⊢ ♖―― x=to            // f1
```
Outside any dash scope: `from == [e1,h1]`, `to == [f1,g1]` after white o-o.

### 3.7 `countmoves`

```
countmoves DASH | countmoves legal DASH | countmoves pseudolegal DASH
```
- Number (always matches, value may be 0 — ⚠️ assumed): number of moves matching the argument. Without legal/pseudolegal:
  PGN moves (respecting variations) — `countmoves ――` = number of children; with target filters, counts moves whose
  targets match (`countmoves ♕――(check) >= 3`). `countmoves legal ―― == 1` ⇒ exactly one legal move.
- ⚠️ AMBIGUOUS: whether promotions to different pieces count as 1 or 4 legal moves (for `move legal count` they
  count as one); whether castling counts once (recommended: once).

### 3.8 `move` filter (deprecated; use ――)

```
move { parameter }*
```

| Parameter | Arg | Meaning |
|---|---|---|
| `from S` | set | move's from square ∈ S |
| `to S` | set | move's to square ∈ S |
| `capture S` | set | move's capture square ∈ S |
| `promote D` | piece designator without squares (`R`, `A`, `[RBN]`) | promotion to one of these types (color ignored) |
| `enpassant` | – | move is e.p. |
| `enpassantsquare S` | set | e.p. capturing a pawn on a square in S |
| `primary` / `secondary` | – | move is primary (doesn't start a variation) / starts a variation |
| `null` | – | null move |
| `castle`, `o-o`, `o-o-o` | – | castling (any / kingside / queenside) |
| `previous` | – | consider only the move that led to the current position; **all set-valued parameters evaluated in the previous position** |
| `legal` / `pseudolegal` | – | consider generated legal / pseudolegal moves instead of PGN moves |
| `count` | – | only with legal/pseudolegal: filter always matches, value = number of matching moves |
| (followed by `comment`) | | see below |

- Move classes: ordinary (PGN moves from the current position; all children with variations), previous, legal, pseudolegal.
- `capture`, `primary`, `secondary`, `promote` cannot be combined with legal/pseudolegal.
- Matches iff some move in the class satisfies **all** parameters.
- **Value**: if the *first* parameter is `from`, `to`, or `capture`, the filter is a **set** filter = union of that
  attribute over all matching moves (`move to . from K legal > 4` = more than 4 legal king destinations;
  `x = move from .` = from square of next move, empty if terminal). With `count`: number. Otherwise logical.
- In `move`, castling's from/to are the **king's** squares (old convention). Null move: from = to = side-to-move king square.
- `move legal`: initial-position e.p. never legal; king/rooks assumed unmoved before the initial position.
  `move legal count` counts promotions differing only by piece type as one move.
- Set args are parsed at `:` precedence (`move from x & y` ⇒ `{move from x} & y`).
- `comment` immediately following a `move` (not legal/pseudolegal): the comment is evaluated in the tail of, and
  attached after, **each** matching move.
- Inside `line` with variations: linearization applies (§4.7).

Examples: `move to _ from K`, `move previous from [QRqr] to _`, `move promote [RBN]`,
`(A & ~move to . previous) attacks k` (discovered check), `move legal from K count == 0`.

### 3.9 `consecutivemoves`

```
consecutivemoves [quiet] [RANGE] (x y)      // x, y position filters
```
- L = lca(x,y); S = moves L→x, T = moves L→y. Value (number) = length of the longest run of consecutive moves in S
  identical to a run of consecutive moves in T. Fails if x or y fails; with RANGE, matches only if value ∈ RANGE.
- Emits comments pairing matched moves (`source-move[1]` … / `target-move[1]` …, apparently derived from the variable
  names ⚠️) unless `quiet` (keyword or header).
- Order of `quiet` and range: doc example `consecutivemoves quiet 15 100 (source target)`; also `consecutivemoves 5 1000 (x y)`.
- "Identical moves" ⚠️ AMBIGUOUS: recommended same from-square, to-square and promotion (cf. lacny.cql helper `S`).

---

## 4. Sequences and searching

### 4.1 ⊢ / `path` — grammar

```
path        := ('⊢' | 'path') pathParam* constituent+
pathParam   := 'primary'
             | ('◎' | 'focus') ['capture'] SETFILTER
             | 'max' NUMERICFILTER
             | 'verbose' | 'keepallbest' | 'piecepath' | 'quiet' | 'nestban' | 'firstmatch' | 'lastposition'
             | 'title' STRINGLITERAL          // ⚠️ an example also shows a bare string literal after ◎♕
constituent := simple [repetition]
simple      := dashConstituent | filterConstituent | chain
dashConstituent   := dash WITHOUT target list   (―― or ×, with optional left/right/=promo)
filterConstituent := any filter (top-level restrictions below)
chain       := '(' constituent+ ')'
repetition  := '*' | '+' | '?' | '{' n '}' | '{' n ',' '}' | '{' ',' n '}' | '{' m ',' n '}'
```
- Parameters come before the first constituent (`⊢ primary ――…`); a later `primary` is the current-move filter
  (babson: `♙――=♗ primary`).
- **Termination**: constituents continue until something that can't be a constituent (closing brace/paren of an
  enclosing construct, end of file) or a **blank line**, which terminates *all* enclosing ⊢ filters.
- ASCII: `path focus . -- --` ≡ `⊢◎▦ ―― ――`.

### 4.2 Parameters

| Param | Arg | Semantics |
|---|---|---|
| `primary` | – | only primary moves are traversed. Not applied to unfocused (skipped) moves under ◎; docs advise not combining with ◎ (use `depth==pathstart:depth` inside instead). |
| `◎ S` / `focus S` | set | focused pieces = pieces standing on S **at the start position** (tracked by identity as they move). Only moves by focused pieces are "in focus". |
| `◎ capture S` | set | as ◎, but captures *of* focused pieces are also in focus. |
| `max N` | numeric filter | choose the matching path that maximizes N evaluated at the tail of the last move (instead of the longest). Value ⚠️ (§8). |
| `verbose` | – | annotate each move of the path. |
| `title "s"` | string literal | with verbose, describe the path by this string in the annotation. |
| `piecepath` | – | with ◎: annotate the path of each focused piece compactly, e.g. `Qa1-a2-b2-b3-c3-c4` (one comment per focused piece). |
| `keepallbest` | – | retain comments (and atomic side effects ⚠️) associated with *each* matching best path, not just one. |
| `quiet` | – | suppress automatically generated comments. |
| `nestban` | – | skip a start position that was already included in a matched path of *this same* ⊢ filter that started at a different (earlier) position. Avoids reporting sub-paths of longer paths. |
| `firstmatch` | – | stop the search after the first matching path is found (no maximization). |
| `lastposition` | – | value is the **tail of the last move** of the matching path (position) instead of its length. |

Default: find the **longest** matching path; value = its length in moves (focused moves only if ◎).

### 4.3 Top-level parsing rules (inside ⊢)

A token is "top level" if not enclosed in `{…}` within this ⊢.
- At top level, `+ * ? {..}` after a constituent are **repetition signals**, and `(` starts a **chain**, not a
  parenthesized filter. ⇒ arithmetic, `legal ――…`, parenthesized expressions must be inside braces:
  `{z=x+3}` OK, `z=x+3` illegal; `{legal ――b4}` OK, `(legal ――b4)` illegal.
- A dash at top level is a dash constituent; inside braces it is an ordinary dash filter (`{――}` is a filter
  constituent meaning "there is a move").
  `⊢ {△―― △――} ――` = any non-terminal wtm position; `⊢ △―― △―― ――` never matches.
- **Repetition attaches to the group "most recent dash constituent + following filter constituents"**:
  `D F1 … Fk R` repeats the sequence `D F1 … Fk`. E.g. `♕♛―― check +` = one or more consecutive queen checks;
  `~T―― +`; `I――*`; `――northeast 1 T ?`. A repeated chain must contain a dash.
  ⚠️ AMBIGUOUS: a repetition after filter constituents with no preceding dash in the group is undefined (recommend error).
- Known 6.2 parser bug (don't need to replicate): a dash constituent immediately followed by a chain without an
  intervening repetition (`⊢ ―― (♕―― ――)+`) fails with "parenthesized expression must contain exactly one filter";
  workaround `⊢ (――) (♕―― ――)+`.

### 4.4 Matching semantics

Let start position S0 = current position. A *path* is a sequence of consecutive PGN moves (down the tree).

Simple constituents Y1..Yk vs moves X1..Xn (recursive definition):
- Y empty and X empty ⇒ match.
- Y1 filter constituent: must match the current position; continue with Y2.. on the same moves.
- Y1 dash constituent: must match move X1 (as a dash filter, evaluated in X1's head); then current position := tail
  of X1; continue with Y2.., X2...
- Chain: flatten (parentheses only group for repetition).
- Repetition: conceptually expand each repetition constituent into a sequence of simple constituents (regex), then
  match. Default expansion choice maximizes the number of matched moves.

Overall:
- ⊢ matches if some path (any length, chosen over all branches when variations are set; only primary moves with
  `primary`) matches the whole constituent sequence. The match need not reach a terminal position (it's anchored at
  the start, not the end).
- Value (number) = number of moves in the chosen matching path (focused moves only under ◎); with `lastposition`,
  value = tail position of the last move. ⚠️ zero-length matches (e.g. `⊢ ――*` at a terminal position, or only filter
  constituents): recommend "matches with value 0".
- Current position restored afterwards. Smart comments: comments produced inside constituents are kept only for the
  chosen path (keepallbest: for each best path).
- Atomic variables [P1]: values are transactional w.r.t. the explored path — on backtracking they revert; at the end
  they hold their values from the end of the matching path. (6.2 bug: atomic requires every ⊢ in the file to have a ◎;
  `⊢◎▦` is the workaround — not to be replicated.) Non-atomic variables keep side effects from every explored branch.
- Values from `from`/`to` in filter constituents are contextual to the preceding dash constituent (§3.6).

Focus (◎) semantics:
- Focused pieces fixed at S0 (pieces on the ◎ set squares), followed by identity (promotion keeps identity [P1]).
- A move is **in focus** if made by a focused piece (castling: if king or rook is focused); with `◎ capture`, also if
  it captures a focused piece. Otherwise **out of focus**.
- When matching a dash constituent, out-of-focus moves are **skipped** (traversed, updating the current position)
  until an in-focus move is reached; that move must match the dash constituent. Filter constituents are evaluated at
  the position reached right after the previous matched (focused) move (before skipping).
- Exception: the **first** move of the path (from S0) must be in focus — unfocused moves are not skipped before the
  first dash constituent (the main loop will retry from later positions anyway).
- Under ◎, `from`/`to` respect focus (castling with ◎♖ ⇒ only the rook).
- Value counts only focused moves.
- Replaces old `singlecolor`: `◎△`, `◎▲`, or `◎ if wtm △ else ▲`.

Examples
```
⊢ ♗×♟h7 check ♚×h7 ♘――g5 check          // Greek gift: value 3 when matched
✵⊢◎T a1――h1 ――h8 ――a8                  // rook visits corners, other moves ignored
⊢◎♕ title "queen staircase" verbose nestban piecepath
   (――up 1 ♕ ――right 1 ♕)+ ――up 1 ♕ ?
⊢◎T∪U T――□ T→C→from ///"crosses " C  U――C  U―― T→C→U    // Turton
◭T∊△ sort "len" ⊢◎T piecepath nestban ――~pathstart:T∩□ {20,} ――pathstart:T∩□
atomic Count=0  ⊢ ―― Count+=1 *        // Count = longest line length
```

### 4.5 Path status filters (experimental)

| Filter | Type | Value |
|---|---|---|
| `pathstart` | position | inside ⊢: its start position. Outside: start position of the most recent matching ⊢. (Index lists it as `pathstatus`.) |
| `pathlastposition` | position | tail of the last matching move of the last matching path (most recent matching ⊢ when outside). |
| `pathcount` | number | inside ⊢: number of focused moves so far from the start to the current position. |
| `pathcountunfocused` | number | unfocused moves so far = `ply - pathstart:ply - pathcount`. Useful with `max` (e.g. maximize delay). |
| `pathdebug` | – | internal use only. |

⚠️ Without ◎ every move is "focused" (pathcount = moves so far) — implied, not stated.

### 4.6 `find`

```
find [quiet] [all | RANGE] ['<--'] FILTER     // ⚠️ parameter order: see below
```
- Search space: **forward** = the current position and all its descendants ("future positions", including variations
  when set; only mainline otherwise). **Backward** (`<--`): the current position and its ancestors (parent chain).
- `find F`: matches if some searched position matches F; value = the **first** such position (position filter);
  search stops at the first hit (order ⚠️: recommended PGN pre-order forward, nearest-first backward).
- `find all F`: value = number of searched positions matching F; matches only if count > 0.
- `find RANGE F`: matches iff count ∈ RANGE (may include 0, e.g. `x = find 0 1000 check`); value = count.
- `quiet`: suppress the auto comments ("Found" etc.) normally placed on found positions (also suppressed by header quiet).
- Argument F parsed at lowest precedence (captures everything after: `find {――=♗} or check` ≡ `find {{――=♗} or check}`).
- ⚠️ AMBIGUOUS order of modifiers: docs show `find quiet check`, `find all check`, `find <-- filter`, "find or find all
  followed by `<--`", and `find <-- quiet all {btm secondary}` (try definition). Recommend accepting `quiet`, `all`/RANGE
  and `<--` in any order before the argument.
- Examples: `find check`, `x = 1 + find all check`, `◭E∊♙a-h2 find E――=△` (excelsior), `find <-- move previous secondary`.

### 4.7 `line` (deprecated; use ⊢)

```
line [RANGE] [firstmatch] [lastposition] [singlecolor] [quiet] [nestban] [primary | secondary]
     ('-->' | '<--') constituent { ('-->' | '<--') constituent }
```
- All arrows in one line filter must be the same direction. `-->` forward (children), `<--` backward (parents).
- Constituent: a filter, or `(` constituents separated by arrows `)`, each optionally followed by `*`, `+`, `?`,
  `{n}`, `{n,}`, `{,n}`, `{m,n}` (6.0 space-separated `{m n}` still accepted, deprecated). `{+}`/`{*}` force wildcard
  reading of `+`/`*` (vs arithmetic).
- Semantics: regex over a *sequence of positions*: constituent 1 must match the current position, constituent 2 the
  next position along the chosen line, etc. Greedy: always matches the longest possible sequence. `.` matches any position.
- Value: number of positions in the longest matched sequence (`line --> check` value 1). With `lastposition`: the last
  position of the sequence. With RANGE: matches only if length ∈ RANGE.
- Params: `firstmatch` stop at first matching sequence; `singlecolor` only positions with the same side to move as the
  start; `quiet`; `nestban` (position can't start a match if already part of a matched sequence of the same line from an
  earlier position); `primary`/`secondary` only follow primary/secondary moves.
- Variations: followed only if `variations` set.
- **Linearization** (variations set): before evaluating, line picks one root-to-leaf line; every `move` filter inside
  is evaluated as if that line's moves were the only moves. Not applied to a `move` nested in `:`, another `line`,
  `move previous`, `find`, or `echo` (so `currentposition:{…}` disables it). With `primary`/`secondary`, only those
  moves are considered for move filters. `-nolinearize` (unsupported) disables globally.
- Examples: `line --> check*>5`, `line 5 100 nestban --> check*`, `line --> move from Q --> not move from Q {10,20} --> move from Q`.

### 4.8 `echo`

```
echo [quiet] (sourceVar targetVar) [in all] BODY
```
- sourceVar := current position (the **source**). For each position P in the game other than the source (all game
  positions, respecting variations — not only descendants), set current position := P, targetVar := P, evaluate BODY.
- `in all` (immediately before BODY): the source itself is also tried as a target.
- Matches iff BODY matched for some target. Afterwards current position is restored and the two variables are reset
  (⚠️ "reset": recommend unbound / previous binding restored).
- If BODY is numeric, echo is numeric: value = **max** of BODY over targets where it matched. Works with `sort` (max
  only; `sort min` with echo not supported). Non-numeric BODY ⇒ logical ⚠️.
- Comments: by default marks each matched source and target (`source <-- move 5(wtm)[47]`, `target <-- move 4(btm) id:47`)
  and the LCA ("LCA") when distinct from both. `quiet` (or header quiet) suppresses. Wrap in `sort` to keep only the
  maximizing pair's comments.
- BODY parsed at lowest precedence; source/target variables scoped to BODY.
- Typical body filters: `:`, `consecutivemoves`, positional `∩`, `sidetomove`, `lca`, `distance`, `≺`, position
  relational ops (`s<t` to examine each pair once).
- Example: `echo(source target){ wtm try source∩target==▦ }`; `sort "len" echo (s t){ btm s∩t==▦ ply-s:ply≥10 }`.

### 4.9 `sort`

```
sort [min] [quiet] ["documentation"] VALUE     // header form: sort matchcount RANGE (§1.2)
```
- VALUE: numeric or string filter; a set filter is sorted by its cardinality (`sort S` ≡ `sort #S`). Parsed at lowest
  precedence (`sort find all check>20` ≡ `sort ((find all check)>20)`).
- Value of `sort` = value of VALUE at this position; fails if VALUE fails.
- Per game, remember the **max** (or **min** with `min`) value attained over all evaluations. Output games sorted
  descending by max (ascending with `min`). Games whose sort never matched get a special "worst" value: always after
  all matched games (in input order), regardless of direction.
- Multiple sort filters: lexicographic in order of appearance in the CQL file.
- Sorts with the same non-empty doc string are merged (max of all), so `⬓ sort "q" ♕` works under transforms.
- Header comment before move 1: doc string + value (suppressed by `sort quiet`).
- Smart comments: only comments associated with the evaluation achieving the max (min) value are kept.
- `min` vs `min(...)` filter: to sort by a min filter, brace it: `sort {min(x y)}`. Doc string order: `sort min "material" power .`.
- Strings: compared as strings (`sort "Date" date` sorts dates descending). ⚠️ AMBIGUOUS: docs say `sort "White player" player white` sorts "alphabetically" though max-sorting is descending.
- Examples: `sort ply` (longest games first), `200<=sort ply`, `sort "Number of pins" pin`, `1800 < sort "Year" year`.

### 4.10 `similarposition`

```
similarposition [nosort] [notransform] "file.pgn"
```
- Matches if some **mainline** position X of some game in the submissions file is *similar* to the current position:
  same side to move and either (a) both pawnless and equal up to a D4 transform, or (b) both with pawns and equal up to
  optional reflection about the vertical bisector followed by a horizontal shift (possibly identity). Castling/ep
  rights ignored. `notransform`: identical boards only.
- Default: matching repository games are output sorted ascending by the game number (in the submissions file) of the
  matching submission position; `nosort` disables. Filename must be a quoted literal.
- `-similarposition [nosort] [notransform] f.pgn` prepends this filter.

---

## 5. Transforms

### 5.1 Syntax, list, general rules

```
TRANSFORM [count] F
```

| Filter | ASCII | Basic transforms |
|---|---|---|
| `✵` | `flip` | D4 (8: id, rotate90, rotate180, rotate270, reflecth, reflectv, reflecta1h8, reflecth1a8) |
| `⬓` | `flipcolor` | {id, invertcolor∘reflecth} |
| `reversecolor` | – | {invertcolor∘reflecth} (**no identity**) |
| `fliphorizontal` | – | {id, reflecth} |
| `flipvertical` | – | {id, reflectv} |
| `rotate90` | – | C4 = {id, rot90, rot180, rot270} |
| `rotate45` | – | C8 = {σ^0..σ^7}, σ = 45° CCW |
| `shift` | – | {H^i ∘ V^j : i,j ∈ −7…7} (225) |
| `shifthorizontal` | – | {H^i : i ∈ −7…7} (15) |
| `shiftvertical` | – | {V^j : j ∈ −7…7} (15) |

- A transform applies only to the **single** next filter; argument parsed at lowest precedence (`⬓ check ♖a1` ≡
  `{⬓ check} ♖a1`; use `⬓{…}`). Pitfall: `shift horizontal` = `shift` applied to `horizontal`.
- All except `reversecolor` include the identity ⇒ `τF` matches whenever F matches.
- Range parameters on transforms are deprecated (use `count`).

### 5.2 Basic transforms on squares and directions

Squares as (f, r) with f,r ∈ 0..7 (a1 = (0,0)):

| Transform | (f, r) ↦ | Direction mapping (vector (df,dr)) |
|---|---|---|
| rotate90 (CCW) | (7−r, f) | (−dr, df): up→left, left→down, right→up, NE→NW |
| rotate180 | (7−f, 7−r) | negate |
| rotate270 (CW) | (r, 7−f) | (dr, −df): up→right |
| reflecth (about horizontal bisector) | (f, 7−r) | up↔down, left/right fixed, NE↔SE, NW↔SW |
| reflectv (about vertical bisector) | (7−f, r) | left↔right, NE↔NW, SE↔SW |
| reflecta1h8 | (r, f) | swap components: up↔right, down↔left |
| reflecth1a8 | (7−r, 7−f) | (−dr, −df) |
| σ (rotate45, C8) | squares: only defined if every square designator is all-64 or empty | rotate 45° CCW: up→northwest→left→southwest→down→… |

Checks from docs: d3 → reflecth d6, reflectv e3, rotate90 f4, reflecta1h8 c4.
Compound directions: under D4 `orthogonal`, `diagonal`, `anydirection` invariant; `vertical`/`horizontal` map to the
union of mapped components (so `rotate90 ray right(..)` ≡ `ray orthogonal(..)` as a whole orbit; `fliphorizontal ray up` ≡ `ray vertical`).
σ: `σ(orthogonal 1 ♔)` ≡ `diagonal 1 ♔`.

Shift units: V = up one rank (defined for ranks 1–7), V⁻¹ down; H = right one file. V^j, H^i powers, i,j ∈ −7..7.

### 5.3 What a transform rewrites (syntactic, applied to the filter tree)

| Element | invertcolor | D4 / σ | shifts |
|---|---|---|---|
| Square designators (`a2`, `[b-d4,g8]`, implicit all-squares of a bare piece designator) | unchanged | squares mapped (σ: only all-64/empty allowed, else filter undefined) | mapped with full-line rule (§5.4) |
| Piece colors (`♔↔♚`, `△↔▲`, `K↔k`), `◭`, `□` unchanged | swapped | – | – |
| `white` ↔ `black` keywords (incl. `elo white`, `player white`, `sidetomove==white`) | swapped | – | – |
| `wtm` ↔ `btm` | swapped | – | – |
| `result 1-0` ↔ `result 0-1` | swapped | – | – |
| Direction keywords/params (`up`, `northeast`, `ray up`, `orthogonal`, …) | – | mapped (§5.2) | unchanged |
| `light F` / `dark F` | – | swapped iff transform maps light squares to dark (reflecth, reflectv, rot90, rot270 swap; rot180, diagonal reflections keep) | each unit shift swaps (`V light F ≡ dark V F`) |

`flipcolor`/`reversecolor` = invertcolor∘reflecth ⇒ colors swapped **and** squares mirrored rank-wise (a2→a7), light↔dark swapped.
Examples: `reversecolor ♔e1 ≡ ♚e8`; `reversecolor 2==△→♚ ≡ 2==▲→♔`; `reversecolor ♔♚h1-8` unchanged;
`reversecolor {player white "Kasparov" result 1-0} ≡ {player black "Kasparov" result 0-1}`;
`reflectv {stalemate right 3 light Qa1&♖b3} ≡ {stalemate left 3 dark Qh1&♖g3}`.

**Not transformed**: `rank`, `file`, `makesquare`; variables (`τ x ≡ x` for a set variable — the board is never
modified); function *definitions* (but invocations are, so transforms "work through" functions); anything under
`notransform`. ⚠️ Not specified: castling keywords (`o-o` under reflectv), `fen`, string literals, `typename`, ranges,
`up 1` counts (counts unchanged).

### 5.4 Square designators under transforms (edge cases)

- Transforms act on each **square designator token** independently (`a1|a8` contains two designators; `[a1,a8]` is one).
- Shift rule for a designator with set S: `V S = { V s : s ∈ S, s not on rank 8 } ∪ { squares of every complete file contained in S }`
  (symmetric for H with complete ranks). Squares shifted off-board are **silently dropped**; full files (for V) /
  full ranks (for H) are invariant.
  `V [a1-8,b3] ≡ [a1-8,b4]`; `H^2V^3 [a-h2,c4] ≡ [a-h5,e7]`; `V^3 a6 ≡ []`; `V[a1,a8] ≡ a2`.
- If any designator in the filter becomes `[]` (empty), the **whole transformed filter is invalid** and is dropped from
  the orbit. `V (a1|a8)` ≡ `a2 | []` ⇒ invalid; hence `shiftvertical {a1|a8}` orbit = {itself}.
- Orbit examples: `shift ♔a1` 64 elements; `shift {♔a1 ♚a8}` 8; `shiftvertical [a1,a8]` 9 (`[a1,a8]`, a1…a8);
  `V a1-8` 1; `D4 a1` 4 corners; `✵a1` value `[a1,h1,a8,h8]`.

### 5.5 Orbit semantics (value of `TRANSFORM F`)

- Orbit Χ F = set of valid filters τF for τ ∈ Χ, with syntactically identical filters de-duplicated (only syntactic:
  `flipcolor count {♔a1 ♚a8}` is 2 even though both elements are equivalent; `shift ✵ count ♔` is 1).
- **Match**: iff some orbit element matches.
- **Set F**: value = union of the values of all orbit elements (non-matching ones contribute ∅).
- **Numeric F**: value = max over matching elements; fails if none match.
- `count`: number value = number of orbit elements that match (0 allowed — always matches ⚠️ assumed).
- Nested transforms compose: `Χ (Υ G)` = orbit of G under Χ∘Υ (`✵⬓`, `shift ✵`).
- Logical/other types: just the match. Sort inside a transform works (max of all). Smart comments: ⚠️ not specified;
  recommend keep comments from matching orbit elements only.
- Efficiency note: large orbits (shift ✵ = 1800) — prefer direction filters.

### 5.6 `notransform`, `currenttransform`

- `notransform F`: value/match of F, ignoring all enclosing transforms (`T notransform F` ≡ `notransform F`).
  Transforms *inside* F still act. (`passedpawns` is internally `notransform ⬓{♙&~down horizontal 0 1 ♟}`.)
- `currenttransform`: string describing the active transforms, right-to-left; always matches. Identity → `<>`;
  e.g. `<reflect_v>`. ⚠️ exact names for each basic transform not documented beyond `reflect_v`.

### 5.7 Command-line transforms

`-flipcolor`, `-reversecolor`, `-flip`, `-shift`, … wrap all subsequent filters (preamble + body).
`cql -flipcolor -cql "Ra3 Kb1 pd3"` ≡ body `⬓{Ra3 Kb1 pd3}`.

---

## 6. Output and annotation

### 6.1 `comment` and `///`

```
comment (arg1 arg2 …)    | comment arg        // single argument: parens optional
/// arg1 arg2 …           // rest of the line = argument list of a comment filter
```
- Always matches (logical). Args are any filters, converted to text like `str` [P1]:
  - string → its value; failing string → `<false>`
  - set (non-piece-variable) → list of squares; piece variable → piece char + square
  - position → `move N(wtm)`/`move N(btm)`; for a variation position also `[positionid]`, and an `id:N` marker is
    emitted at that position itself
  - number → decimal
  - filter without value → `<true>` / `<false>`
  - `currenttransform` → transform string
- Placement: attached to the move leading to the current position (before the game for the initial position). Inside a
  dash target / ⊢ / find / `move … comment`, "current position" is the temporary one.
- `////` (4+ slashes) is a normal line comment; `//` not followed by `/` is a line comment; `/* … */` block comment.
- Precedence pitfall: `///` consumes to end of line; `comment` single-arg form takes one filter.

### 6.2 Smart comments (transactional comment buffer)

- Comments generated inside a filter are discarded if that filter (ultimately the enclosing filter) does not match:
  `{/// "x" ♖==K}` emits only if the compound matches; in ⊢, per-move comments survive only for the chosen path;
  whole-body failure discards all comments from that position's evaluation.
- With `sort`: only comments associated with the max (min) value are output.
- `-alwayscomment` disables smart comments.
- Known 6.2 bug (don't replicate): ⊢ without ◎ with variations may leak comments from a rejected shorter branch.
- Implementation: maintain a stack of comment buffers; push on entering a filter that can fail/backtrack, commit to
  parent on success, drop on failure; sort keeps per-sort-key buffer of the best evaluation.

### 6.3 Comment levels

Kinds: (1) user comments; (2) CQL-generated (find, echo, ⊢, line, sort, consecutivemoves); (3) header comments (game
number, sort values); (4) matchstring at matched positions.
- Default: all. `quiet` (header/`-quiet`): only user + header comments (⚠️ docs say "only user-generated comments and
  header comments", implying matchstring is also suppressed; the parameter table says "suppress automatically generated
  comments except for header comments"). `silent`/`-silent`: none. Command line wins over header.
- Per-filter `quiet` keyword: `find quiet`, `echo quiet`, `⊢ … quiet`, `sort quiet`, `consecutivemoves quiet`, `line … quiet`.
- `matchstring ""` / `-matchstring ""` suppresses (4).

### 6.4 `message`

```
message [quiet] (args…) | message [quiet] arg
```
- Same argument conversion as comment; writes immediately to **stdout** (at evaluation time, regardless of later
  failure). Prefix: move number, side to move, game number, and positionid if in a variation. `quiet` ⇒ only the text.
  Always matches. Intended for debugging.

### 6.5 `originalcomment` / `hascomment`

```
originalcomment                // string: the PGN comment at the current position; fails if none
originalcomment "lit"          // logical: search/NAG test
hascomment "lit"               // synonym (6.0 compatible)
```
- "Comment at position P" = comment attached to the move leading to P (pre-move-1 comment for the initial position).
- With a string literal: fails if no comment; if the literal denotes a NAG → matches iff that NAG is present; else
  substring search in the comment.
- NAG literals: `$n` (digits) or symbolic: `!`=1, `?`=2, `!!`=3, `??`=4, `!?`=5, `?!`=6, `=`=10, `+/=`=14, `=/+`=15,
  `+/-`=16, `-/+`=17, `+-`=18, `-+`=19.
- Unaffected by `removecomment` and by comments CQL adds.
- Examples: `originalcomment ~~ "Eval: (\d+)"`, `"bad" in originalcomment`, `originalcomment "$6"`.

### 6.6 `removecomment`

- No args; always matches. Marks the original comment of the current position for deletion **on output only**
  (doesn't affect hascomment/originalcomment). Disabled by `-noremovecomment`.

### 6.7 `settag`

```
settag ("TagName" VALUE)       // first: string literal; second: string (or int per filter table)
```
- Sets a PGN header tag on **output** only; tag filters still see original values. Always matches unless args fail.
- Forbidden names: Event, Site, Date, ECO, FEN, Round, Result, EventDate, and anything starting with White/Black.
- Disabled by `-nosettag`. Example: `initial settag("hhdbgame" gamenumber)`.

### 6.8 `readfile` / `writefile`

- `readfile FILENAME` (string filter arg): value = file contents (string). Extension must be .pgn, .cqo or .cql.
  Halts CQL if the filename filter fails, bad format, or read error. Otherwise always matches. Forces single thread.
  Typically guarded by `if (initial and gamenumber==1)`.
- `writefile (FILENAME MESSAGE)` (both string filters): first call for a filename truncates the file, later calls
  append. Extension must be .cqo. Halts on failing args or write error. Forces single thread. ⚠️ match/value not
  stated; recommend logical, always matches.

### 6.9 `matchstring`

Header `matchstring "s"` / `-matchstring s`: text inserted at every matched position (default `CQL`; `""` = none).

### 6.10 `hhdb` (summary only)

Special-purpose interface to the HHdbVI endgame-study database (Heijden 6). `hhdb KEY [args]` where KEY is one of
a fixed set of soft keywords (reusable as variable names; quote ones with punctuation: `"(c)"`, `"<main>"`):
status flags (`sound`, `unsound`, `cooked`, `correction`/`(c)`, `twin`/`TW`, `anticipation`/`AN`, `U1`…`U5`, …),
string fields (`composer`, `stipulation`, `gbr [kings|material|pieces|pawns]`, `search`, `firstcomment`, `diagram`)
with implicit-search string literal argument, numeric award filters (`prize`, `hm`, `commendation`, `award`,
`special`, `max`, `egdiagram`) whose value is the min (or `max`) award rank, `hhdb sort award`, and tree filters
`hhdb mainline` / `hhdb variation` that honour `<main>` comment tags
(`hhdb variation` ≡ `find <-- move previous secondary and not hascomment "<main>"`). Command line: `-hhdb KEY [arg]`,
`-hhdb help`. Low priority for an SDK; can be implemented as a plugin.

### 6.11 Deprecated filters (still accepted)

| Deprecated | Replacement |
|---|---|
| `ancestor(x y)` | `x ≺ y` |
| `descendant(x y)` | `x ≻ y` |
| `attackedby` | `←` [P1] |
| `attacks` | `→` [P1] |
| `xray` | `→` chains [P1] |
| `colortype` | `piecename` [P1] |
| `type` | `typename` [P1] |
| `line` | `⊢` |
| `move` | `――` |
| `hascomment` | `originalcomment` |
| `piecepath` *filter* (not the ⊢ parameter) | to be removed |
| `∪=`, `∩=` (and ASCII `|=`, `&=`) | `X = X ∪ Y` |

---

## 7. Evaluator context checklist

The evaluator needs, at each evaluation:
1. `game`, `currentPosition` (stack for push/restore by `:`, find, echo, ⊢, dash target, line).
2. `variationsEnabled` (tree visibility for all walkers; `-virtualmainline` is top-level only).
3. **Dash scope** stack: (left set L, right set R, focus set) for contextual `from`/`to` (§3.6); reset when entering
   `:`/find/echo.
4. **Path state** stack: start position, focused piece ids, pathcount, pathcountunfocused, last matching path info
   (for `pathstart`/`pathlastposition` after completion), nestban memo per ⊢ instance (per game), atomic-variable
   snapshots.
5. **Transform context**: transforms are best implemented at compile time by producing the orbit of rewritten
   filter trees (with syntactic dedupe and `notransform` barriers), plus a runtime string for `currenttransform`.
6. **Comment buffers** (smart comments, §6.2), output-side tag/comment edits (settag/removecomment), per-game sort
   keys (max/min, merged by doc string), matchcount.
7. Line-filter linearization context (selected root-to-leaf line) for nested `move` filters.

---

## 8. Open ambiguities (consolidated)

1. Position visiting order with variations (assume PGN pre-order) — §1.3; `find` forward search order likewise.
2. `quiet` header: whether the matchstring "CQL" is suppressed (two doc statements differ) — §6.3.
3. positionid numbering for variation positions (only ordering constraints given) — §2.1.
4. `movenumber` for FEN-started games — §2.1.
5. `primary`/`secondary` at the initial position — §2.2.
6. Exact binding power of ―― left/right operands ("extremely low" vs `x=♘――(to)` behaviour) — §3.3.
7. Value of an un-targeted ―― (set of origin squares — only from the filter overview page) and of a ―― whose last
   target filter is logical — §3.3.
8. ―― handling of null moves (assume king from/to own square); `×` errors on null moves in 6.2.
9. `currentmove`: where left/right/target filters are evaluated — §3.4.
10. Value of `legal`/`pseudolegal`; FEN castling rights for legality; how countmoves legal counts promotions — §3.5, §3.7.
11. Contextual castling doc typos: "from will have value of [e1,g1]" vs `from==[e1,h1]`; `x= ♔―― // x==e1` presumably
    meant `♔――(from)` (or the set value of the dash) — §3.6.
12. ⊢ `title` syntax (`title "s"` vs bare string in explain-staircase); `max` effect on the returned value; exact
    `keepallbest` semantics (all equally-best paths vs all matching paths; effect on side effects); zero-length matches;
    repetition after a dash-less group; `pathcount` without ◎ — §4.2–4.5.
13. explain-turton writes `⊢T∪U` (missing ◎) — treat as `⊢◎T∪U`.
14. `find` modifier order (`find <-- quiet all …`) — §4.6.
15. `echo`: "variables are reset" meaning; value type when body non-numeric — §4.8.
16. `sort` on strings: "alphabetically" vs descending max — §4.9.
17. Transforms on `o-o`/`o-o-o`, `fen`, strings; `currenttransform` names; smart comments inside transforms; whether
    `count` form always matches — §5.3, §5.5, §5.6.
18. `consecutivemoves`: definition of identical moves; comment labels — §3.9.
19. `writefile` return/match — §6.8.
20. Shift naming: shift page calls horizontal U/vertical V while transformformal uses U for the upward unit shift;
    irrelevant to semantics (this doc uses H = horizontal, V = vertical).
21. Unicode table on the unicode page swaps the ASCII of → and ← (palette is correct: `→` = `->`, `←` = `<-`) [P1].
