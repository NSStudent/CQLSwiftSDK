# CQL 6.2 — Language Core Reference (implementation-oriented)

Source: CQL 6.2 documentation (gadycosteff.com/cql), condensed and paraphrased.
Scope: lexer, values/types, precedence/parsing, variables & control flow, operators, strings,
position predicates & set filters, game-metadata filters.

**Out of scope (covered in a sibling reference):** game-tree navigation (`parent`, `child`, `position`,
`positionid`, `currentposition`/`∙`, `initial`, `terminal`, `ply`, `movenumber`, `depth`, `mainline`,
`variation`, `lca`, `distance`, `ancestor`/`descendant` semantics), moves (`――`/`--`, `×`/`[x]`, `move`,
`legal`, `pseudolegal`, `from`, `to`, `currentmove`, `o-o`…), `⊢`/`path`/`line`, `◎`/`focus`, `find`,
`echo`, transforms (`✵`, `⬓`, `shift`…, `notransform`), `comment`/`///`/`originalcomment`, `sort`,
CQL header parameters. They are referenced here only where needed for lexing/precedence.

Conventions used below:

* **matches** = "the filter is true in the current position"; **fails** = does not match.
* **value** = the datum a matching filter represents (set / number / string / position) — see §2.
* Types: `Set` (set of squares), `Num` (32-bit int), `Str`, `Pos` (game-tree node), `Logical`
  (no value), `PieceVar`, `Dict`.
* `⚠️ AMBIGUOUS:` marks places where the docs are silent, contradictory or (apparently) wrong. A
  recommended resolution is given where one is reasonable. All are collected in §7.

---

## 1. Lexical structure

### 1.1 Source text

* A `.cql` file is a byte sequence; non-ASCII characters are UTF-8. Every non-ASCII token has an ASCII
  equivalent; files may freely mix both (the reference tool converts with `cql -a` / `cql -u`).
* Characters outside the CQL symbol set → "unknown character" error (e.g. `—` em-dash is NOT `-`;
  `→` is not `-->`).
* File layout (header details: sibling doc): `cql ( header-params ) body…`. The body is an
  **implicit compound filter**: all top-level filters, as if enclosed in `{ }`.

### 1.2 Whitespace and comments

* Whitespace (space, tab, CR, LF) separates tokens and is otherwise insignificant. Newlines are not
  statement terminators. **Juxtaposition is the statement separator**: two filters separated only by
  whitespace are never one filter (`♘b2 check` is two filters).
* Places where whitespace is **forbidden** (lexically significant adjacency):
  * inside a piece designator (`♖a1-8`, `[a1,h1]`, `[PqR]a-h2`);
  * between `◭` and the piece-variable name in `◭x=…` / `◭x∊…`;
  * inside a `――`/`×` move filter between components, and before its `(target…)` list (sibling doc);
  * inside multi-char operators (`==`, `<=`, `-->`, `[element]`, …).
* Comments:

| Form | Meaning |
|---|---|
| `// …` to end of line | ignored — **unless** the `//` is immediately followed by exactly one more `/` |
| `/// …` to end of line | NOT a comment: syntactic sugar for `comment ( … )` with the rest of the line as the argument list (sibling doc) |
| `//// …` (4 or more slashes) | ignored to end of line |
| `/* … */` | ignored (may span lines) |

  ⚠️ AMBIGUOUS: nesting of `/* */` and `//` inside string literals are unspecified. Recommend: no
  nesting (first `*/` closes); comment markers inside `"…"` are literal text.

### 1.3 Token inventory

Multi-character ASCII operators (use **maximal munch** in this order):

| Token(s) | Meaning | Notes |
|---|---|---|
| `-->` `<--` | path/line arrows | sibling doc |
| `--` | move filter (= `――`) | sibling doc |
| `->` `<-` | attack arrows `→` `←` | §5.5. Note `x<-1` lexes as `x <- 1`; write `x < -1` |
| `==` `!=` `<=` `>=` `<` `>` | relational | §4.10 |
| `=?` | conditional set assignment | §4.2 |
| `+=` `-=` `*=` `/=` `%=` | operator assignment | §4.2 |
| `\|=` `&=` (also `∪=` `∩=`) | set op-assign, **deprecated** (to be removed) | §4.2 |
| `~~` | regex match | §4.13 |
| `=` | assignment | |
| `+ - * / %` | arithmetic; `+` also string concat; `+ *` also path quantifiers | |
| `\| & ~` | union, intersection, complement | §4.12 |
| `#` | cardinality / string length / dict size | §5.11 |
| `:` | evaluate-at-position; also slice separator inside `[m:n]` | §4.14, §4.13 |
| `( )` | argument list or parenthesized single filter | §3.1 |
| `{ }` | compound filter (also regex-count `{m,n}` inside paths: sibling doc) | |
| `[ ]` | many uses — see §1.9 | |
| `,` | only inside compound square designators (and path repetition bounds) | |
| `.` | `▦` (all 64 squares); also wildcard char inside `fen "…"` strings | |
| `_` | empty-square piece type (`□`) | |
| `?` | path quantifier (sibling doc) | |
| `\` | standalone string escapes / capture refs | §1.6 |
| `o-o` `o-o-o` | keywords containing `-` (castling, sibling doc) — must be lexed before identifier `o` | |

### 1.4 Unicode symbols and ASCII equivalents

| Unicode | Codepoint | ASCII | Meaning |
|---|---|---|---|
| `♔♕♖♗♘♙` | U+2654–2659 | `K Q R B N P` | white piece types |
| `♚♛♜♝♞♟` | U+265A–265F | `k q r b n p` | black piece types |
| `△` | U+25B3 | `A` | any white piece |
| `▲` | U+25B2 | `a` | any black piece |
| `◭` | U+25ED | `[Aa]` | any piece; also prefix for piece variables (`◭x=…`, `◭x∊…`) |
| `□` | U+25A1 | `_` | empty square |
| `▦` | U+25A6 | `a-h1-8` or `.` | all 64 squares |
| `≤ ≥ ≠` | U+2264, 2265, 2260 | `<= >= !=` | relational |
| `∪ ∩` | U+222A, 2229 | `\| &` | union / intersection |
| `∊` | U+220A | `[element]` | iteration (§4.8) |
| `∀` | U+2200 | `[forall]` | universal iteration (§4.8) |
| `→` | U+2192 | `->` | attacks (§5.5) |
| `←` | U+2190 | `<-` | attacked-by (§5.5) |
| `≺ ≻ ≼ ≽` | U+227A–227D | `[<] [>] [<=] [>=]` | ancestor / descendant relations (relational precedence; semantics sibling doc) |
| `――` | U+2015 U+2015 | `--` | move filter (sibling doc) |
| `×` | U+00D7 | `[x]` | capture move filter (sibling doc) |
| `⊢` | U+22A2 | `path` | sibling doc |
| `◎` | U+25CE | `focus` | sibling doc |
| `✵` | U+2735 | `flip` | transform (sibling doc) |
| `⬓` | U+2B13 | `flipcolor` | transform (sibling doc) |
| `∙` | U+2219 | `currentposition` | sibling doc |

⚠️ AMBIGUOUS (doc typos): the unicode-page table lists `▲` as U+25B3 (same as `△`; actual HTML entity
is U+25B2) and swaps the codepoints/ASCII of `→`/`←` (`→`=U+2192=`->`, `←`=U+2190=`<-` is correct, per
the hover titles and the attack pages). `――` is two U+2015 characters; a single U+2015 is not a token.

### 1.5 Numbers

* Decimal integer literals, 32-bit signed. No floats, no hex.
* A number literal is a numeric filter that always matches; value = itself.
* Negative literals appear as `-4`, in ranges (`-1 1`) and direction ranges (`up -2 d4`).
  Recommend: lex `-` separately and let the parser fold unary minus on literals.
* Numeric **variables** must stay within |value| ≤ 1 000 000 000.
* ⚠️ AMBIGUOUS: overflow behaviour of arithmetic is unspecified.

### 1.6 String literals and escapes

* Quoted: `"…"` (straight double quotes). **No escape processing inside quotes**: `"pin\n"` has 5
  characters (`p i n \ n`). A quoted literal cannot contain `"`.
* **Standalone predefined strings** (each is itself a string literal token, outside quotes):

| Token | Value |
|---|---|
| `\n` | LF |
| `\t` | TAB |
| `\r` | CR |
| `\"` | `"` |
| `\\` | `\` |

  Example: `"pin" + \n + "mate"`; `#("pin" + \n) == 4`; `"pin\n"[3] == \\`.
* **Capture-group references** (§4.13): `\0`, `\1`, … (`\` + literal non-negative integer) → Str
  value of that group of the most recent `~~` match; `\-0`, `\-1`, … → Num index of that group in the
  target.
* Inside regex patterns, backslashes are passed through to the regex engine (`"\d+"`, `"\x22"`).
* To match a `"` with a regex, use `\x22` in the pattern (a `\"` cannot be embedded in a literal).
* ⚠️ AMBIGUOUS: whether a quoted string may span lines is unspecified. Recommend: allow (raw bytes).
* ⚠️ AMBIGUOUS: multi-digit capture refs (`\10`) unspecified. Recommend: allow any digit run.

### 1.7 Identifiers (variable / function / dictionary names) and keywords

* Characters: `A–Z a–z 0–9 $ _`. Case-sensitive. ⚠️ AMBIGUOUS: may a name start with a digit? Not
  stated; recommend **no** (would collide with numbers).
* Must not be a keyword, and must not be a string that is a **piece designator** (`R`, `_`, `Ba3`,
  `ab3`, `_c1`, `a`, `b`, `K`, `A`, …). Hence `x y z` are fine, `a b` are not.
* Names starting with `__CQL` or `cql__` are reserved.
* Keywords (core-relevant; the documentation "index" page is the authoritative list): `abs all and
  anydirection ascii assert atomic attackedby attacks between black btm check colortype connectedpawns
  dark date diagonal dictionary doubledpawns down eco else elo event eventdate false fen file forall
  from function gamenumber horizontal idealmate idealstalemate if in indexof int isbound isolatedpawns
  isunbound lastgamenumber left light local loop lowercase makesquare mate max message min modelmate
  modelstalemate northeast northwest not or orthogonal passedpawns persistent piece pieceid piecename
  pin player power puremate purestalemate quiet rank ray result right sidetomove site southeast
  southwest sqrt square stalemate str tag then through to true type typename unbind up uppercase
  vertical while white wtm xray year` + all sibling-doc keywords (`cql path find echo move legal
  pseudolegal comment sort flip flipcolor shift… parent child position currentposition initial
  terminal…`). `then` is an optional legacy keyword (§4.7). `string` appeared as an iteration keyword in
  a 6.2 beta (`string Key in D …`) — legacy.

### 1.8 Piece designators (grammar)

A piece designator is a single token denoting a **Set**: (squares whose content matches the piece-type
part) ∩ (squares named by the square part). Missing piece part = any content (incl. empty); missing
square part = all 64 squares.

```ebnf
PieceDesignator  ::= PieceTypePart? SquarePart?          (* at least one present; no whitespace inside *)
PieceTypePart    ::= SimpleType | '[' SimpleType+ ']' | UnicodeType UnicodeType+
SimpleType       ::= AsciiType | UnicodeType
AsciiType        ::= 'K'|'Q'|'R'|'B'|'N'|'P'|'k'|'q'|'r'|'b'|'n'|'p'|'A'|'a'|'_'
UnicodeType      ::= '♔'|'♕'|'♖'|'♗'|'♘'|'♙'|'♚'|'♛'|'♜'|'♝'|'♞'|'♟'|'△'|'▲'|'□'|'◭'
SquarePart       ::= SimpleSquare | '[' SimpleSquare (',' SimpleSquare)* ']'
SimpleSquare     ::= FileSpec RankSpec
FileSpec         ::= File ('-' File)?          (* File  ::= 'a'..'h' *)
RankSpec         ::= Rank ('-' Rank)?          (* Rank  ::= '1'..'8' *)
```

| Type char | Meaning | Type char | Meaning |
|---|---|---|---|
| `K Q R B N P` / `♔♕♖♗♘♙` | white king…pawn | `k q r b n p` / `♚♛♜♝♞♟` | black king…pawn |
| `A` / `△` | any white piece | `a` / `▲` | any black piece |
| `_` / `□` | empty square | `◭` | any piece (= `[Aa]`) |

* Compound type `[Ak]`, `[K_]`, `[Aa_]` = union of the listed types. Brackets may be omitted only
  when **all** type chars are Unicode: `♖♗a4` ≡ `[RB]a4`, `△♚`, `◭□`.
* Ranges: `a-h3` (rank 3), `d4-5`, `a-h1-8`, `e-f7-8`. Compound squares: `[a1,h1,a8,h8]`,
  `[b-h2,d5,e-f7-8]` — commas, no whitespace. Union of the parts.
* Examples: `b2`, `Q`, `[Qq]`, `♕♛`, `♕a3`, `[PqR]a-h2`, `♙♛♖a-h2`, `A[b-h2,d5,e-f7-8]`, `_f1-8`, `□f1-8`.
* `▦` / `.` and `[]` (empty set) are separate set-constant tokens (not combinable with a type part).
* Piece designators are affected by transforms (sibling doc); designator **literals** are the units a
  transform rewrites.
* ⚠️ AMBIGUOUS: example table lists `Qu` = "white queen" (likely typo for `♕`); the index lists `Aa`
  as a synonym of `◭` (bracket-less `Aa` is not derivable from the grammar — `a` without rank is not a
  square). Recommend: reject both. Whether ASCII and Unicode chars may mix inside `[...]` (`[♖B]`) is
  unspecified; recommend allow. Range order (`h-a`, `8-1`) unspecified; recommend error or normalize.

### 1.9 The many meanings of `[`

Lex greedily, in this priority (the lexer decides; the docs explicitly say `[a2]` is a designator
even after a dictionary name):

| Text | Token |
|---|---|
| `[x]` | capture `×` (so `D[x]` is NOT a subscript — write `D[ x ]`) |
| `[element]` `[forall]` | `∊` `∀` |
| `[<]` `[>]` `[<=]` `[>=]` | `≺ ≻ ≼ ≽` |
| `[]` | empty set constant |
| `[` piece-type chars `]` (+ optional square part) | piece designator |
| `[` square list `]` | piece designator |
| any other `[` | subscript open (string index/slice, dictionary key) — closed by `]` |

A subscript `[` follows a primary (variable, literal, parenthesized expr); whitespace before it is
allowed (`"mate" [1:-1]`, `F[ a2 ]`). ⚠️ AMBIGUOUS: the dictionary page both says `[a2]` is always a
designator (needs `D[ a2 ]`) and shows `Dict[a3]="knight"`. Recommend lexer rule above (spaces required)
— or special-case: if the previous token is a known dictionary name and no whitespace precedes `[`,
treat as subscript.

### 1.10 Recommended lexing algorithm / lexical ambiguities

1. Skip whitespace/comments (`///` → emit a `TripleSlash` token carrying the rest of the line).
2. Try Unicode symbols (incl. `――` pair, figurine runs + optional square part).
3. Try multi-char operators (maximal munch, §1.3) and bracket tokens (§1.9).
4. At `[A-Za-z_$0-9]`: if digit → number. Else try `o-o-o`/`o-o`; else try the piece-designator
   regex; accept it only if the **next char is not an identifier char** (`[A-Za-z0-9_$]`). Otherwise
   read the maximal identifier run and classify keyword vs identifier.
   * `ab3` → designator (black piece on b3); `ab` → identifier; `x-1` → `x` `-` `1`;
     `h-1` → identifier `h`, `-`, `1`; `c`/`e`/`h` alone → identifiers (no rank).
   * `_` alone → empty-square designator; `_c1` → designator; `_foo` → identifier.
5. `◭` immediately followed by an identifier (no space) and then `=`/`∊`/`[element]` → piece-variable
   prefix form (§4.2, §4.8); otherwise `◭` is the any-piece designator (`◭a1` = designator).

Known lexical/semantic collisions:
* `-` (minus / negative literal) vs `--` (move) vs `->`/`-->` (arrows) vs hyphens in designators and
  `o-o`. `x--1` must be written `x - -1`.
* `a` = black-piece designator, but `a` is also a file letter inside squares (`a1`, `a-h`).
* `x` is a normal identifier, but `[x]` is the capture token.
* `_` = empty square, but allowed inside identifiers.
* `.` = all squares (`~.` = empty set); inside `fen "…"` strings `.` means "any content".
* `white`/`black` are numeric constants **and** parameters of `player`, `elo`.
* `result 1-0` / `0-1` / `1/2-1/2`: these lex as number/operator sequences; the `result` parser must
  reassemble them (or accept a quoted string, §6).
* ⚠️ AMBIGUOUS: the docs use `K∊E` and `R∊F` (dictionary iteration with designator-shaped variable
  names), contradicting §1.7. Recommend: treat as doc error (reject), or allow a designator-shaped
  identifier only immediately before `∊`.

---

## 2. Values, types and matching

### 2.1 Every filter is evaluated at the current position and yields (matched?, value?)

| Kind | Has value? | Value when it fails | Matches iff |
|---|---|---|---|
| Logical (`check`, `mate`, `in`, `and`, `not`, …) | never | — | its own condition |
| Set | **always** | empty set | value is non-empty |
| Numeric | only when it matches | none | filter-specific; literals & numeric variables always match |
| Position | only when it matches | none | filter-specific |
| String | only when it matches | none | filter-specific; literals always match |

* A **set** filter that fails is indistinguishable from one whose value is ∅ (e.g. `[]` never
  matches; `x` where `x` holds ∅ fails).
* **Numeric variables always match** but the parser rejects a numeric variable used purely as a
  condition (`if x …` → error: "no reason to test if x matches").
* "Value" of a filter can only ever be one of: Set, Num (int32), Pos, Str. Logical filters have none.
* Some filters have a type that depends on operands (`+` is Num or Str; `if` takes its branch type;
  compound takes last constituent's type). Types are **static** (resolved at parse time; variable
  types fixed by first assignment).

### 2.2 Type catalogue

| Type | Representation | Notes |
|---|---|---|
| Set | 64-bit square set | piece designators, `▦`, `[]`, `→`, `|`, square vars… |
| Num | Int32 | |
| Str | byte string (ASCII ordering) | |
| Pos | reference to a game-tree node | compared by `positionid` with `< <= > >=`; by ancestry with `≺…` |
| PieceVar | piece id (stable across moves/promotions) | **evaluates as a Set**: {square of that piece} or ∅ if it is gone |
| Dict | map, single key type, single value type | not first-class: cannot be passed/returned |
| Logical | — | |

### 2.3 Implicit conversions

| Context | Conversion |
|---|---|
| Relational op with exactly one Set operand and one Num operand | Set → its cardinality (`△==3` ≡ `#△==3`; `△→♚>1`) |
| `==` / `!=` with two Set operands | set equality (works even if both empty); **no numeric value** |
| `< <= > >=` with two Pos operands | compare `positionid` |
| `∩` with two Pos operands | positional intersection → Set (§4.12) |
| PieceVar anywhere | → Set (current square or ∅), except: (a) output in `comment`/`message`/`str` (prints piece + square), (b) passed to a user function (stays a piece variable) |
| `str`/`comment`/`message` arguments | see §4.13 conversion table |
| `sort` with a Set argument | cardinality (sibling doc) |
| `if` with both branches same type | that type; else no value |
| compound `{…}` | type/value of its last constituent (Set → ∅ if compound fails) |

⚠️ AMBIGUOUS: relational `< <= > >=` with **two Set** operands is unspecified (only `==`/`!=` are
defined). Recommend: compare cardinalities, or reject at parse time.

---

## 3. Parsing and precedence

### 3.1 Structural rules

* **Compound** `{ f1 f2 … fn }` (n ≥ 0): matches iff every constituent matches, evaluated left to
  right with **short-circuit** (stop at first failure). Value = value of `fn` (when matched); if `fn` is
  a Set the compound is a Set filter (∅ on failure). `{}` matches. Constituents are parsed at the
  **lowest** precedence.
* **Parenthesized single filter** `( f )`: highest precedence primary; content parsed at lowest
  precedence; must contain exactly one filter ("parenthesized expression must contain exactly one
  filter"). `(2+4)*3` ≡ `{2+4}*3`.
* **Argument list** `( a1 a2 … )`: only directly after a filter that takes a parenthesized list
  (`between`, `ray`, `xray`, `max`, `min`, `str`, `message`, `comment`, `indexof`, `makesquare`,
  user-function calls, and sibling-doc ones: `echo`, `distance`, `lca`, `ancestor`, `descendant`,
  `consecutivemoves`, `child(n)`, …). Arguments are separated by **juxtaposition**; there are no commas.
  `(♖a3 or ♘b2 check or stalemate)` = 2 args.
* **Prefix filters** (name before argument) take a single argument without parentheses (`not x`,
  `#x`, `abs x`, `power x`); multi-arg prefix filters use an argument list.
* **Infix**: `and or in → ← attacks attackedby ~~ :` and symbolic operators.
* Prefixes with optional parts are resolved by lookahead: optional range (`up 1 3 d4`), optional
  keyword params (`pin from …`, `elo white`, `player black`, `message quiet`, `persistent quiet`,
  `square all`), optional quoted string (`fen "…"`, implicit search `site "x"`).

### 3.2 Precedence table (lowest → highest), with 6.2 symbols placed

All binary operators are **left-associative** except `:` and the relational operators (**right**).

| Lvl | Operators / argument positions | Notes |
|---|---|---|
| P0 | `-->`, `<--` inside `line` | sibling doc |
| P1 | `+`, `*` wildcards inside `line` | sibling doc |
| P2 (LOWEST) | args of `find`, `if`/`then`/`else`, `loop`; transform args (`✵ ⬓ shift…`); bodies of `echo`, `piece`, `square`, `sort`; compound constituents; args of `ancestor`, `descendant`, `distance`, `lca`; user-function call args; parenthesized single filter. **Inferred 6.2:** body of `x∊Z F` / `∀x∊Z F` / dict iteration; `while` body | |
| P3 | `or` | |
| P4 | `and` | |
| P5 | `not` (prefix; its argument parsed at P5) | `not a and b` = `(not a) and b` |
| P6 | `in` (binary) | |
| P7 | `<  <=/≤  ==  >=/≥  >  !=/≠` **and** `≺ ≻ ≼ ≽` (`[<] [>] [<=] [>=]`) | right-assoc, chainable |
| P8 | numeric-argument prefixes: `makesquare`, `abs`, unary `-`(?), RHS of `+= -= *= /= %=`, RHS of `persistent`, `sqrt`, `position` | arg parsed "just below `+`" |
| P9 | `ascii`, `int`, `#` | |
| P10 | binary `+`, `-` | |
| P11 | `lowercase`, `uppercase` | |
| P12 | unary `-` | see ⚠️ below |
| P13 | `*`, `/`, `%` | |
| P14 | set-argument prefixes: `rank`, `file`, `in` param of `piece`/`square`, `between` args, `power`, `type`, `colortype`, RHS of piece assignment (`piece x =` / `◭x=`), `pieceid`. **Inferred:** `typename`, `piecename`, domain of `∊` | arg parsed "just below `|`" |
| P15 | `\|` / `∪` | |
| P16 | `&` / `∩` | |
| P17 | `~` (prefix complement) | |
| P18 | `attacks`, `attackedby`, **`→`/`->`, `←`/`<-`** | arrows form n-ary chains (§5.5) |
| P19 | `from`/`to`/`through` parameter values of `pin` | |
| P20 | direction filters (`up` … `anydirection`), `light`, `dark` (their set argument) | |
| P21 | `x[…]` string/dictionary subscripting; `~~` "(on the left)" | see ⚠️ |
| P22 (HIGHEST) | `:` | right-assoc |
| — | primaries: literals, designators, `▦ [] true false`, variables, `( f )`, `{ … }`, keyword filters without args | |

**How to read the table for prefix filters.** A prefix filter listed at level L parses its argument as
an expression containing only operators of level > L (Pratt: `parseExpr(minBP = L+1)`), and the
prefix itself is then an operand at that level. E.g. `rank x & y` ≡ `rank (x & y)`; `# Q|K` ≡
`#(Q|K)`; `power a attackedby Q` ≡ `power (a attackedby Q)`; `up ♖|♙` ≡ `(up ♖)|♙`;
`light ♗>1` ≡ `(light ♗)>1`; `sqrt 4 + 8<9 + 5` ≡ `(sqrt (4+8)) < (9+5)`;
`abs x<3` ≡ `(abs x)<3`; `x: f * g` ≡ `(x:f) * g`; `makesquare (2 + 3 3 + 4)` ≡ `makesquare((2+3) (3+4))`.

**Type-directed extension (inferred, required to reproduce the documented examples).** The parser
only absorbs a following binary operator into a prefix's argument if the result is type-valid for that
argument; otherwise it stops and the operator applies to the prefix's result:

| Expression | Parse | Why |
|---|---|---|
| `ascii 65 + 2` | `ascii (65+2)` → `"C"` | Num+Num valid |
| `ascii 65 + "C"` | `(ascii 65) + "C"` → `"AC"` | Num+Str invalid |
| `int "32" + "1"` | `int ("32"+"1")` → 321 | Str+Str valid |
| `int "32" + 1` | `(int "32") + 1` → 33 | Str+Num invalid |
| `#♖ + #♛` | `(#♖) + (#♛)` | Set+Num invalid |
| `position 0 : child` | `(position 0) : child` | `:` needs a Pos on the left |
| `ascii ascii C - ascii "A" + ascii "a"` | `ascii((ascii C) - (ascii "A") + (ascii "a"))` | documented |

### 3.3 Precedence examples (documented)

```
2+3*4<4/2+1              ≡ (2+(3*4)) < ((4/2)+1)
check or not mate and Q or stalemate ≡ check or ((not mate) and Q) or stalemate
A | ~B&Q | q             ≡ A | ((~B)&Q) | q
1+2*3<4*5+6              ≡ (1+(2*3)) < ((4*5)+6)
#□←♔                     ≡ #(□←♔)
□←♚>#□←♔                 ≡ (#(□←♚)) > (#(□←♔))
square x in A rank x<3   ≡ square x in A (rank x<3)
A attacks k | n          ≡ (A attacks k) | n
4 ≤ ♙<7                  ≡ 4 ≤ (♙ < 7)              (right-assoc chain)
sort △ ≥ 10              ≡ sort (△ ≥ 10)
```

### 3.4 Pitfalls (lowest-precedence arguments capture everything until juxtaposition)

* `find {――=♗} or check` ≡ `find ({――=♗} or check)`. Write `{find ――=♗} or check`.
* Single-filter bodies: `square x in ▲ ♕→x ♘→x` ≡ `{square x in ▲ ♕→x} ♘→x` — the second `x` is out of
  scope → runtime error "attempt to access unbound variable x" (no line number). Use braces.
* Same for `piece`, `echo`, `∊`, transforms (`⬓ pin through ♖ ♖→♕` ≡ `{⬓ {pin through ♖}} ♖→♕`).
* `shift horizontal` is two filters; `shifthorizontal` is one keyword.

### 3.5 Ambiguities in the precedence material

* ⚠️ AMBIGUOUS: `abs #♕>sqrt #♜ + #♛` is documented as `(abs #♕) > ((sqrt #♜) + #♛)`, contradicting the
  stated rule that `sqrt`'s numeric argument absorbs `+` (`sqrt 4+8 ≡ sqrt(4+8)`). Recommend: follow
  the rule (`sqrt (#♜ + #♛)`), treat the example as erroneous.
* ⚠️ AMBIGUOUS: unary `-` appears twice: at P8 ("numeric argument to `-` parsed just below `+`", i.e.
  `-x+1` ≡ `-(x+1)`) and at P12 (conventional, `(-x)+1`). Recommend P12 (conventional); negative
  literals fold at lex/parse time either way.
* ⚠️ AMBIGUOUS: `~~` is said to bind tighter than `+` (table P21, "on the left"), but the ~~ page's
  examples state `X+Y ~~ "tba"` ≡ `(X+Y) ~~ "tba"`. Recommend: the **left operand of `~~` absorbs
  string `+`** (i.e. place `~~` just below P10, above P9/P8), follow the examples. The right operand is
  always a single string literal so it never absorbs anything.
* ⚠️ AMBIGUOUS: the compound page says `not ♖a3 or ♗b5` is one `not` over the `or`; the filter and
  precedence pages (and the table) say `(not ♖a3) or ♗b5`. Recommend the table.
* ⚠️ AMBIGUOUS: the precedence page says the set arg of `#` is parsed "just below `|`" while the table
  puts `#` at P9. With type-directed extension both give identical results for sets; for strings use P9
  (`#"ab"+"c"` = 3).
* ⚠️ AMBIGUOUS: not in the table at all — assignment `=`/`=?` RHS, `str`/`message` single arg without
  parens, `isbound`/`unbind` operand, `dictionary`, `assert` arg, `while` test/body, `∊` domain, `∀`.
  Recommended: `=`/`=?` RHS parsed at **P6+** (absorbs relational and arithmetic, not `in/not/and/or`):
  `x = a < b and c` ≡ `(x = (a<b)) and c`; `assert` arg at P2 (lowest); `str X`/`message X` single arg at
  P8; `∊` domain at P14; `while` body at P2; `if`/`∊`/`square` may start any operand position (they are
  primaries whose trailing parts extend at their own levels), e.g. `X = if (Y>0) "check" else "mate"`,
  `3 ≤ x∊▲ △→x→♚`, `y = z∊△ z――`.

---

## 4. Variables, control flow and operators

### 4.1 Variables: kinds, binding, scope

| Kind | Created by | Value / matching |
|---|---|---|
| Numeric | `x = <Num filter>` | Int; always matches when bound |
| Set | `x = <Set>`, `x =? <Set>`, `square x in…`, `x∊Z…` | Set; matches iff non-empty |
| String | `x = <Str>` | Str |
| Position | `x = <Pos filter>` (e.g. `z = currentposition`) | Pos |
| Piece | `piece x = S`, `◭x = S`, `piece x in…`, `◭x∊Z…` | piece id; evaluates to Set |
| Dictionary | `dictionary D`, `local dictionary D` | §4.5 |

* Type fixed at first assignment (parse-time); re-assigning a different type is an error.
* Non-persistent variables become **unbound at the start of each game**. Using an unbound variable →
  runtime error "attempt to access unbound variable" (parse-time if obviously undefined).
* Iteration variables (`square`, `piece`, `∊`, `echo`) are scoped to the single body filter that
  follows.
* User variables are otherwise global to the CQL file (functions alias them, §4.6).

### 4.2 Assignment forms

| Syntax | Applies to | Matches | Effect |
|---|---|---|---|
| `v = F` | Num / Str / Pos | iff `F` matches | assigns `F`'s value; on failure `v` unchanged |
| `v = S` | Set | **always** | assigns `S` (may be ∅) |
| `v =? S` | Set | iff `S` non-empty | assigns only when non-empty |
| `v += F` `v -= F` `v *= F` `v /= F` `v %= F` | Num | iff RHS matches (and, presumably, divisor ≠ 0) | `v = v op F`; RHS parsed at P8 |
| `v += F` | Str | iff RHS matches | append |
| `v \|= S`, `v &= S` (`∪=`, `∩=`) | Set | — | **deprecated**; use `v = v ∪ S` |
| `piece v = S` / `◭v=S` (no space after `◭`) | Piece | iff `S` is exactly one **occupied** square | binds `v` to that piece's id; else `v` unchanged |
| `v[i] = s`, `v[m:n] = s` | Str variable | iff indices valid | §4.13 |
| `D[k] = v` | Dict entry | iff `k`, `v` match | inserts/overwrites |
| `persistent [quiet] v = F` / `persistent [quiet] v op= F` | Num / Str / Set | as above | declares persistent (§4.3) |
| `atomic v = F` | Num / Str (/Set?) | as above | declares atomic (§4.3) |

* ⚠️ AMBIGUOUS: whether an assignment has a *value* (e.g. `y = (x = 3)`) is unspecified. Recommend:
  assignments are Logical.
* ⚠️ AMBIGUOUS: variables page example `X[1:3]=Z // X holds "zZzwang"` is inconsistent with the slice
  rules (`Z` is also an undefined variable there). Ignore it; strings page is normative.

### 4.3 `persistent`, `atomic`, `local`

* `persistent x = 3`, `persistent y += 1`, `persistent quiet X = ""`. Only Num, Str, Set.
  * Initialized **once** to `0` / `""` / `∅`; retains value across games. The assignment itself is an
    ordinary filter re-executed each time it is evaluated.
  * Must not have been used non-persistently earlier in the file. Bare declaration `persistent x`
    (no assignment) is an **error** since 6.1.
  * At end of run, all persistent variables are printed (`name: value`) unless declared `quiet`.
  * Any persistent variable/dictionary forces single-threaded execution (implementation note).
* `atomic X = 4`: transactional inside `⊢` (values rolled back on failed path branches) — sibling doc.
  Not supported for dictionaries or piece variables.
* `local` only prefixes `dictionary` (§4.5).

### 4.4 `isbound`, `isunbound`, `unbind`

| Filter | Type | Semantics |
|---|---|---|
| `isbound V` | Logical | true iff variable name `V` currently has a value |
| `isunbound V` | Logical | negation |
| `unbind V` | Logical (always matches) | removes `V`'s value |
| `unbind D[k]` | Logical | deletes entry; matches unless `k` fails to match |
| `unbind D` | Logical, always matches | deletes all entries |

Use case: overriding defaults from the command line (`-assign`).

### 4.5 Dictionaries

* Declare: `dictionary D` or `local dictionary D` (prefix keyword on **first use**); may combine with a
  first assignment: `dictionary D["tmp"] = "none"`.
* Default **persistent** (survives across games). `local` → cleared before each game.
* Keys and values: any of Str, Num, Set, Pos (**Pos only in local dictionaries**). One key type and one
  value type per dictionary (may differ from each other). Types inferred at parse time from the first
  use; a dummy initial entry may be needed for inference.
* Access `D[k]`: value of entry; **fails** if no such key. Assign `D[k] = v`.
* `#D` = number of entries (6.2 beta notes say this errored; docs say supported).
* Iteration: `K∊D body` (ASCII `K [element] D body`) — `K` successively bound to each key, `body`
  evaluated. ⚠️ AMBIGUOUS: match/value of dictionary iteration and key order are unspecified. Recommend:
  matches iff body matched for some key (like `∊` over squares), Logical; insertion order.
* Dictionaries cannot be function arguments or values of filters; always referenced by name.
* `atomic` not supported for dictionaries.
* ⚠️ AMBIGUOUS: example `dictionary E["1"]=="2"` (with `==`) is presumably a typo for `=`.

### 4.6 User-defined functions

```
function NAME ( p1 p2 … ) { body… }      // params: identifiers, whitespace-separated; body is a compound
NAME ( a1 a2 … )                          // call; arity must match; args parsed at P2
```

* Semantics = **macro expansion** at the call site:
  1. For each actual arg: if it is a variable, the formal is renamed to that variable (**by
     reference**: assignments to the formal modify the caller's variable). Otherwise a fresh hidden
     variable is created and assigned the arg's value (`{_v1=[Qq] _v2=[Rr] {#_v1<#_v2}}`).
  2. Evaluate the renamed body in place of the call. Value = value of body.
* Wrap an argument in `( )` / `{ }` to force by-value: `ChangeA((x))`.
* Piece-variable actuals stay piece variables (track the piece if the body changes position); set
  variables do not.
* Recursion (direct or indirect) is forbidden (CQL crashes; we should reject at parse time).
* Transforms apply to the expanded body at the call site, not to the definition.
* Unused final value → warning/error (e.g. body ending in a bare variable whose value is discarded).
* ⚠️ AMBIGUOUS: whether a function must be defined before its first call, whether its name may shadow
  a variable, and whether definitions are allowed in nested scopes are unspecified. Recommend: top-level
  only, define-before-use. Also `function square(x){x * x}` appears in the filter table although
  `square` is a keyword — treat as doc error.

### 4.7 Control and logic

| Filter | Syntax | Type | Semantics |
|---|---|---|---|
| `true` | `true` | Logical | always matches |
| `false` | `false` | Logical | never matches |
| `not` | `not F` | Logical | matches iff `F` fails |
| `and` | `L and R` | Logical (never a value) | ≡ `{L R}` but valueless; short-circuit |
| `or` | `L or R` | Logical | `R` not evaluated if `L` matches |
| `if` | `if C [then] T` | value: none | matches iff (C ∧ T) ∨ ¬C — **matches when `C` fails and no else** |
| `if…else` | `if C [then] T else E` | type of T if T, E same type | matches iff (C ∧ T) ∨ (¬C ∧ E); value from the taken branch |
| `while` | `while ( T ) B` | Logical | repeat: evaluate `T`; if it matches evaluate `B`; stop when `T` fails. **Always matches.** Parens around test required |
| `while ~~` | `while ( S ~~ "re" ) B` | Logical | §4.13 iterative regex form |
| `loop` | `loop B` | Logical | evaluate `B` repeatedly until it fails; matches iff `B` matched at least once |
| `assert` | `assert F` | (F's?) | if `F` fails, CQL halts reporting the line number; else matches |

* `then` is optional (deprecated). Dangling `else` binds to nearest `if` (standard).
* ⚠️ AMBIGUOUS: `loop` doc says "matches if body was ever true, that is if body was evaluated more
  than once" — the two phrasings coincide (body true once ⇒ evaluated twice). Recommend "body matched
  ≥ 1 time". Infinite loops are the user's problem.
* ⚠️ AMBIGUOUS: `assert` value unspecified; recommend Logical.

### 4.8 Iteration over squares and pieces

| Syntax (Unicode) | ASCII equivalent | Var kind | Type | Matches | Value |
|---|---|---|---|---|---|
| `square x in S B` | — | square (Set, 1 sq) | **Set** | iff value ≠ ∅ | {s ∈ S : B matches with x=s} |
| `square all x in S B` | — | square | Logical | iff B matches for **every** s ∈ S (vacuously true if S=∅) | — |
| `piece x in S B` | — | piece | **Set** | iff value ≠ ∅ | {s ∈ S occupied : B matches with x = piece on s} |
| `piece all x in S B` | — | piece | Logical | iff B matches for every piece on S (vacuous true) | — |
| `x∊S B` | `x [element] S B` | square | Set | iff some s ∈ S makes B match | {s ∈ S : B matches} |
| `◭x∊S B` | ⚠️ (see below) | piece | Set | iff some piece on S makes B match | squares in S of such pieces |
| `∀x∊S B` | `[forall] x [element] S B` | square | Logical | iff all s ∈ S make B match (vacuous true) | none |
| `∀◭x∊S B` | ⚠️ | piece | Logical | iff all pieces on S make B match | none |
| `K∊D B` | `K [element] D B` | dict key | see §4.5 | | |

* `S` (domain / `in` parameter) is evaluated **once** in the current position before iterating.
* Body `B` = exactly one filter (lowest precedence; use `{…}` for several). Body value ignored.
* `square`/`∊` variable holds a one-square Set; `piece`/`◭` variable tracks the piece (its square
  follows the piece in later positions, e.g. `◭y∊♙a-h2 find y――=♖`).
* `x∊S B` ≡ `square x in S B`; `∀x∊S B` ≡ `square all x in S B`; `◭`-forms ≡ `piece` forms.
* Examples: `x∊a-h8 ♖→x` (≡ `♖→a-h8`); `1==x∊▦ ♖→x and ♗→x`; `3≤x∊▲ △→x→♚`; `∀x∊□←♚ 1==△→x`;
  `2≤ ◭y∊♙a-h2 find y――=♖`; `square all z in A power z<2`.
* No space allowed between `◭` and the variable.
* ⚠️ AMBIGUOUS: the ASCII form of `◭x∊…` (`[Aa]x[element]…`?) is not documented; recommend accepting
  `piece x in S B` as the ASCII spelling and having `cql -a`-style conversion emit that.
* ⚠️ AMBIGUOUS: may the iteration variable shadow / reuse an existing variable? Recommend: allowed if
  same kind; restored (or unbound) after the body.

### 4.9 `in` (binary filter, P6)

| Operands | Matches iff |
|---|---|
| Set `in` Set | left ⊆ right (∅ ⊆ anything → matches) |
| Str `in` Str | left is a substring of right (literal, no regex); fails if either side fails |

* Logical (no value). Unrelated to the `in` *parameter* of `square`/`piece`/`echo`.
* Pitfall: a captured piece variable is ∅ ⇒ `x in a-h8` matches; use `x & a-h8` instead.
* Examples: `N in A`, `"h" in "hello"`, `♖♘♗♕ in puremate`, `typename to in "RNB"`.

### 4.10 Relational operators (P7, right-associative)

| ASCII | Unicode | Operand types |
|---|---|---|
| `<` `<=` `>` `>=` | `≤` `≥` | Num, Str (lexicographic by byte value), Pos (by `positionid`), Set↔Num (set→count) |
| `==` | — | Num, Str, Set (set equality if both sets), Pos, Set↔Num |
| `!=` | `≠` | **defined as `not { L == R }`** |
| `[<] [>] [<=] [>=]` | `≺ ≻ ≼ ≽` | Pos only (ancestor/descendant — sibling doc) |

* **Matching**: fails if either operand fails (except `!=`, which is `not ==` and therefore matches
  when an operand fails: `5 != parent:#△` matches at the initial position).
* **Value** (when it matches): the value of the **left operand** (Num, Str or Pos). No value for
  `!=`, nor for `==` on two Sets.
* Hence chaining via right-assoc: `4 ≤ ♙ < 7` ≡ `4 ≤ (♙<7)`; `"a" ≤ X ≤ "z"`; `X≺Y≺Z` (value X).
* String order: byte/ASCII value, `""` < everything, `"A" < "a"`, `"Ab" > "A"`.
* Common use: `distance(s t) ≥ 5` as last filter of a sorted body yields the distance.
* ⚠️ AMBIGUOUS: Pos `==` Pos semantics not spelled out; recommend node identity. 6.2 notes a minor
  change in the "datatype of chained relational operators on positions" vs 6.1 without detail.
* ⚠️ AMBIGUOUS: Str vs Num comparison (e.g. `"3" < 4`) unspecified; recommend parse error.

### 4.11 Arithmetic and numeric functions

| Filter | Syntax | Result | Matches iff |
|---|---|---|---|
| `+ - * / %` | binary, Num×Num | Num | both operands match; `/` and `%` also need right ≠ 0 |
| unary `-` | `-F` | Num | `F` matches |
| `abs` | `abs F` (P8) | Num | `F` matches |
| `sqrt` | `sqrt F` (P8) | Num = ⌊√F⌋ | `F` matches and `F ≥ 0` |
| `min`, `max` | `min(a b …)` / `max(a b …)`, ≥ 2 args, all Num or all Str | Num/Str | **at least one** arg matches (result over matching args) |

* `/` is integer division. ⚠️ AMBIGUOUS: rounding for negatives and sign of `%` unspecified;
  recommend C/Swift truncation semantics (`-7/2 == -3`, `-7%2 == -1`).
* `min`/`max` here are unrelated to `sort min` (sibling doc). `max("pin" "mate") == "pin"`.
* `white` ≡ 1, `black` ≡ -1 (numeric constants, §5.4).

### 4.12 Set operators

| Filter | Syntax | Type | Semantics |
|---|---|---|---|
| union | `L \| R`, `L ∪ R` (P15) | Set | L ∪ R |
| intersection | `L & R`, `L ∩ R` (P16) | Set | L ∩ R |
| positional intersection | `P1 ∩ P2` / `P1 & P2` with **Pos** operands | Set | squares whose contents (type+color, or both empty) are identical in the two positions; ≡ `square z in . P1:colortype z == P2:colortype z` |
| complement | `~S` (P17) | Set | 64 squares minus S |
| empty set | `[]` | Set | ∅ (≡ `~.`); never matches |
| all squares | `▦` / `.` / `a-h1-8` | Set | all 64; always matches |

Examples: `pin ∪ {♖→♚}`, `~(source∩target)`, `mismatches == △∩source:□`.

### 4.13 Strings

**Literals & basics**

| Construct | Type | Notes |
|---|---|---|
| `"…"` | Str | always matches; no escapes inside |
| `\n \t \r \" \\` | Str | standalone literals |
| `L + R` (both Str) | Str | concatenation; fails if either fails |
| `#S` | Num | length |
| `S[i]` | Str (1 char) | 0-based; negative `i` → `#S+i`; fails if out of range after adjustment |
| `S[m:n]` | Str | chars `m … n-1`; `m` default 0, `n` default `#S`; negative → `#S+v` (once); clamped (`"mate"[1:100]=="ate"`); `m ≥ n` → `""`; matches whenever `S`, `m`, `n` match |
| `V[i] = s` / `V[m:n] = s` | assignment (V a Str **variable**) | replaces that char/range with `s` (any length; `x[0:0]="b"` prepends). `V[i]=…` fails (no change) if `i` out of range |
| comparisons, `in`, `min`/`max` | | §4.9–4.11 |

Slice examples: `"mate"[0:2]=="ma"`, `"mate"[1:-1]=="at"`, `"mate"[-2:-1]=="t"`, `"filename.cql"[-4:]==".cql"`.
Assignment example chain: `x="a"`; `x[0]="hello"` → `"hello"`; `x[-2]="c"` → `"helco"`; `x[5]="z"` fails.
⚠️ AMBIGUOUS: the documented chain `x="ba"; x[2:2]="This" // "bahis"` contradicts the rules (should be
`"baThis"`), and the following lines are computed from the wrong value. Implement the rule, not the example.

**Conversion filters**

| Filter | Syntax / prec. | Arg | Result | Fails when |
|---|---|---|---|---|
| `str` | `str(a1 a2 …)` or `str X` (one arg) | any filters | Str = concatenation of converted args | never (always matches) |
| `ascii` | `ascii F` (P9) | 1-char Str | Num (code) | arg fails, or length ≠ 1 |
| `ascii` | `ascii F` (P9) | Num 1–255 | Str (1 char) | arg fails, or out of range |
| `int` | `int F` (P9) | Str matching `-?[0-9]+` | Num | otherwise |
| `indexof` | `indexof (x y)` | Str Str | Num = 0-based index of first occurrence of `x` in `y` (literal) | either fails, or not found |
| `lowercase` / `uppercase` | prefix (P11) | Str | Str (ASCII letters converted) | arg fails |
| `makesquare` | `makesquare "b3"` | Str | Set (one square) | string isn't a square name (§5.8) |

**`str` / `message` / `comment` conversion rules** (shared):

| Argument | Output |
|---|---|
| Str filter | its value; `<false>` if it fails |
| Num filter | decimal; `<false>` if it fails (e.g. `str(2<1 K)` → `"<false>e1"`) |
| Set filter | the squares (e.g. `e1`) — ⚠️ AMBIGUOUS: exact multi-square format unspecified; recommend designator style `[a1,h1]` |
| PieceVar | piece letter/figure + square (`♔d4` / `Kd4`) — ⚠️ AMBIGUOUS which glyph; outputs seen both |
| Pos filter | `move N (wtm|btm)`; if in a variation also the `positionid` |
| Logical | `<true>` / `<false>` (doc once writes `<false;>`, a typo) |
| `currenttransform` | name of current transform (sibling doc) |

**Implicit-search disambiguation inside `str`/`message`/`comment` argument lists:** if a filter that
takes an implicit search parameter (§6) or `fen` is followed by a string literal, the literal is a
separate argument: `str(F "lit")` ≡ `str({F} "lit")` (e.g. `message(player white " is White")`).

**Regex match `~~`**

* Syntax: `target ~~ "pattern"` — `target` any Str filter; `pattern` a **string literal** (quoted or
  `\n`-style). ⚠️ AMBIGUOUS: non-literal patterns (variables) unsupported per docs; recommend reject.
* Matches iff the pattern is found anywhere in the target (search, not full match).
* Value: the matched substring (can be `""`, which still matches: `"hello" ~~ "z*"`).
* Side effect: sets capture registers `\0` (whole match), `\1`… (groups) — Str; `\-0`, `\-1`… —
  Num index of each in the target. ⚠️ AMBIGUOUS: value/behaviour of `\i` before any match, for
  unmatched optional groups, and register scope (global vs per-filter) are unspecified. Recommend:
  global "last successful match" registers; referencing a missing group fails.
* Dialect: C++ `std::regex` ECMAScript. `.` never matches newline. `^`/`$` anchoring with embedded
  newlines is platform-dependent in CQL; recommend ECMAScript non-multiline (anchors = whole target).
  Swift: `NSRegularExpression` without `.anchorsMatchLines`/`.dotMatchesLineSeparators` is closest.
* Examples: `"football" ~~ "[otba]+"` → `"ootba"`; `player white ~~ "K.*ov"`; `date ~~ "2004\.03\."`.
* Extract numbers: `Target ~~ "Eval: (\d+)"  Val = int \1`.

**`while (S ~~ "re") body`** (iterative form)

* `S` evaluated once → target. Then repeatedly find the next match left-to-right (non-overlapping),
  set `\0…`, evaluate `body`. Stops when no further match. Matches unless `S` fails.
* ⚠️ AMBIGUOUS: empty-match advancement (e.g. `while (Lines ~~ ".*")`) unspecified; recommend
  ECMAScript global semantics (advance by one char after an empty match). Effect of mutating `S`
  inside the body unspecified (doc example `S[\-0]=" "` mutates in place with equal-length replacement);
  recommend iterating over the original snapshot.

### 4.14 `:` (evaluate at another position) and `message`

* `P : F` — `P` a Pos filter, `F` any filter (parsed at P22, so `x:f*g` ≡ `(x:f)*g`; right-assoc:
  `position 0 : child : F`). Evaluate `P` → p; set current position to p; evaluate `F`; restore.
  Matches iff `P` matches and `F` matches at p; value = `F`'s value at p.
  Examples: `parent:check`, `s:sidetomove`, `{find check}:positionid`, `source:(x&_)`.
  Note: piece variables evaluated after `:` give the piece's square in p; set variables don't change.
* `message [quiet] (a1 a2 …)` / `message X`: converts args like `str`, writes to stdout immediately,
  prefixed with move number, side to move, game number (+ positionid if in a variation) unless
  `quiet`. Always matches (Logical).

---

## 5. Position predicates and set filters

### 5.1 Attack definition (used by everything below)

Piece `u` on square s **attacks** square t iff a king of the opposite colour placed on t would be in
check from `u`. Consequences: pawns attack their two forward diagonals regardless of occupancy or side
to move; pinned pieces still attack; a piece attacks squares occupied by its own side ("defends");
sliding pieces are blocked by any piece in between; side to move is irrelevant.

### 5.2 `check`, `mate`, `stalemate`

| Filter | Type | Matches iff |
|---|---|---|
| `check` | Logical | a king is in check (≡ `⬓ △→♚` ≡ `△→♚ or ▲→♔`) |
| `mate` | Logical | side to move is in check and has no legal move |
| `stalemate` | Logical | side to move is not in check and has no legal move |

### 5.3 Pure / model / ideal mate and stalemate

All six are **Set** filters: value = set of squares of **participating pieces** (∅ ⇒ no match).
Definitions below are for **black mated / stalemated** (black to move); the white case is the colour
mirror.

**Definitions used**

* *King's field* F: squares adjacent to the black king (excluding the king's square).
* White piece x **guards** y ∈ F iff x attacks y, or x would attack y if the black king stood on y
  (i.e. attack computed with the king removed from its square — the king's body does not block).
* *Refutation square*: a square whose occupation by black would break the mate: a checking piece's
  square, or a square between a checking piece and the black king. ⚠️ AMBIGUOUS: the doc also lists
  "the white king" as a refutation square (meaning unclear — possibly a typo); recommend ignoring it.
* *Potential refuter*: a black piece that, ignoring checks and pins, could make a pseudolegal move to
  a refutation square.
* *Necessary pin*: a pin whose removal would let the pinned black piece affect the mate (interpose or
  capture a checker). If the king is in double check there are no necessary pins.
* *Necessary double check*: each check could be refuted (checker captured or interposed) if the other
  check did not exist — counterfactually removing only that other checker's attack on the king square.

**`puremate`** — position is `mate` (black mated) and:
1. every empty square of F is guarded exactly once;
2. every square of F holding a white piece is guarded exactly once;
3. every square of F holding a black piece is unguarded, or guarded once "by a necessary pin";
4. the mate is a single check, or a necessary double check.

⚠️ AMBIGUOUS: rule 3's "guarded once by a necessary pin" — recommend: the black self-block may be
guarded exactly once, and only by the piece that pins it, and that pin is necessary.

Participants (value) for a pure mate of black:
* white pieces that: check the king; or attack/guard a square of F; or are pinned; or (no double
  check) pin a potential refuter; or (no double check) stand between a potential refuter and a
  refutation square it would otherwise reach;
* black pieces that: are the king; are adjacent to the king; block a check by black on the white king;
  or (no double check) block a move by a black piece to a refutation square.

⚠️ AMBIGUOUS: participant rule "is checking a square adjacent to the black king" — recommend "guards".

**`modelmate`** ≡ `⬓{ btm puremate ♖♘♗♕ in puremate }` — pure mate where every non-king non-pawn piece
of the mating side participates. Value = participants (∅ if not model).
**`idealmate`** ≡ `◭ == puremate` — every piece on the board participates. Value = participants.

**`purestalemate`** — position is `stalemate` (black) and:
1. each empty square adjacent to bK is attacked exactly once by white;
2. each white piece adjacent to bK is attacked exactly once by a white piece;
3. each unpinned black piece adjacent to bK is not attacked by white;
4. each pinned black piece adjacent to bK is not attacked by white.
   ⚠️ AMBIGUOUS: rules 3 and 4 are identical as written; the intended rule 4 is probably "attacked at
   most once, by its pinner". Recommend the latter (parallels puremate rule 3).

Participants: white pieces that are pinned, that pin a black piece, or that attack a square adjacent to
bK; **all** black pieces.
**`modelstalemate`** ≡ `⬓{ btm purestalemate ♖♘♗♕ in purestalemate }`.
**`idealstalemate`** ≡ `◭ == purestalemate`.

Examples: `puremate not modelmate`; `puremate btm sort "# black participants" ▲&puremate`.

### 5.4 Side to move and colour constants

| Filter | Type | Value / match |
|---|---|---|
| `wtm` | Logical | white to move |
| `btm` | Logical | black to move |
| `white` | Num | 1 (always matches) |
| `black` | Num | -1 |
| `sidetomove` | Num | 1 if white to move, -1 if black |

Idioms: `sidetomove == white`, `sidetomove == x:sidetomove`. (`white`/`black` are also parameters of
`player`, `elo`.)

### 5.5 Attack relations: `→ ← attacks attackedby xray ray between pin`

**Binary arrows** (P18)

| Syntax | Matches iff | Value (Set) |
|---|---|---|
| `X → Y` / `X -> Y` | some piece on X attacks some square in Y | squares of X holding a piece that attacks some square of Y (≡ `x∊X x→Y`) |
| `Y ← X` / `Y <- X` | same condition as `X → Y` | squares of Y attacked by some piece on X |
| `X attacks Y` (deprecated) | as `X → Y` | as `X → Y` |
| `Y attackedby X` (deprecated) | as `Y ← X` | as `Y ← X` |

Examples (start position): `♙→f3` = [g2,e2]; `△→f3` = [g2,e2,g1]; `♙←♘` = [e2,d2]; `▦←♚` = king's
field; `▦←♕==27`; `△→♚>1` = double check; `_ attackedby k == 8` (mirror-mate field).
⚠️ AMBIGUOUS: the attacks page shows `not △ attacks (□ ♚)` for "no empty square of the king's field is
attacked" — a two-filter parenthesis is illegal; presumably `(□ attackedby ♚)` was meant.
⚠️ AMBIGUOUS (doc typo): "value of X→Y is the set of squares in Y that attack a square in Y" — read
"squares in X".

**Arrow chains** `x1 → x2 → … → xn` (n ≥ 3) are a single n-ary filter (not nested binaries); use parens
to nest: `♝→(♖→♔)` = bishop attacks a rook that attacks the king, vs `♝→♖→♔` = rook pinned by bishop.

* Single-square case: chain holds iff the squares x2…x(n-1) lie strictly between x1 and xn on one line,
  every other square between x1 and xn is empty, and x1 holds a (sliding) piece that would attack xn if
  x2…x(n-1) were all emptied. Intermediate squares need **not** be occupied
  (`h1→h2→h4→h7→h8` is true in the start position; `h1→h3→h7→h8` is false because h2 is occupied and not
  listed). No colour constraints (`d1→d2→d7`, `♕→♙→h8` are valid).
* Ternary restatement: a sliding piece on x attacks y, y is between x and z, squares x..y and y..z
  empty. Typical: `♖→▲→♚` (black piece pinned by white rook), `⊢ ―― from→d4→to` (move crosses d4).
* General sets: holds iff some choice X1∈x1, …, Xn∈xn satisfies the single-square case.
* Value: set of X1 ∈ x1 for which some completion exists (e.g. `△→▲→♚` = white pinning pieces).
* `←` chains: `xn ← … ← x1` matches iff `x1 → … → xn`; value = squares of **xn** (the first written
  operand) for which a completion exists.
* ⚠️ AMBIGUOUS: (a) must X2…X(n-1) appear in order along the line from X1 (recommend yes) and be
  distinct (yes); (b) mixed chains `a→b←c` unspecified (recommend parse error); (c) the docs claim
  `x→y→z` ≡ `pin from x through y to z`, but `pin` imposes colour rules and requires a piece on y while
  the arrow chain does not — treat the arrow as colour-agnostic per its examples.

**`xray (s1 s2 … sn)`** (deprecated; Set): ≡
`ray orthogonal ({s1&[RrQq]} s2 … sn) | ray diagonal ({s1&[BbQq]} s2 … sn)`. Intuition: first is a line
piece, which would attack the last but for the pieces in between (`xray (R a k)` = rook pins black
piece to black king; `xray (Q A K)`).

**`ray [dir] (s1 s2 … sn)`** (Set)

* `dir`: any direction keyword (§5.6); default `anydirection`. Basic directions of `dir` are allowed.
* Matches iff there is a sequence of n **distinct** squares S1…Sn along a single ray (straight line in
  one allowed basic direction, ordered in that direction) with Si ∈ si, and **no pieces on the squares
  strictly between consecutive Si**. Si themselves may be empty (`ray up (♔ □ ♙ ♟ □ ♚)`).
* Value: set of squares that "terminate" a matching sequence. ⚠️ AMBIGUOUS: "terminate" = last square
  Sn (recommended) or first S1?
* Examples: `ray orthogonal (♖ ♞ ♚)` ≡ `♖→♞→♚`; `ray diagonal (c6 e4 f3)`; `ray (♔ ♟)` fails if a
  piece stands between.

**`between (s t)`** (Set; args at P14): squares strictly between some x∈S and y∈T where x,y lie on a
common queen line (rank, file or diagonal); independent of occupancy. `between(a1 c3)` = b2;
`between(a1 h7)` = ∅.

**`pin [from F] [through T] [to Z]`** (Set; parameter values at P19, i.e. `pin through △>2` ≡
`(pin through △)>2`)

* A pin = (pinning piece, pinned piece, to-square): pinner is a sliding piece (R/B/Q along its own
  lines); pinned piece has the **other** colour; the to-square is empty or holds a piece of the
  pinned piece's colour; the pinned piece is the only piece between pinner and to-square, and the
  pinner would attack the to-square if the pinned piece were removed.
* Defaults: `from ◭`, `through ◭`, `to ♔♚` → bare `pin` = pieces pinned against their own king.
* Matches iff some pin satisfies all three constraints. Value = squares of the role named by the
  **first** parameter written (`from` → pinners, `through` → pinned, `to` → to-squares); no
  parameters → `through` (pinned pieces).
* Examples: `pin`, `pin from ♕`, `pin through a`, `pin from ♕ through ♜ to ♚`, `pin > 4`,
  `pin through △ ≥ 3`.

### 5.6 Direction filters

* Basic: `up down left right northeast northwest southeast southwest` (white's perspective; `up` =
  increasing rank).
* Compound: `vertical` = up,down; `horizontal` = left,right; `orthogonal` = the four rook directions;
  `diagonal` = the four bishop directions; `anydirection` = all eight.
* Syntax: `DIR [range] S` — range = one or two integers (literals or numeric variables; may be
  negative; second ≥ first); default `1 7`; `S` parsed at P20 (`up ♖|♙` ≡ `(up ♖)|♙`).
* Value (Set): union over k in range and over basic directions d of `S` shifted k steps along d
  (squares falling off the board are dropped). k = 0 yields `S` itself; negative k shifts in the
  opposite direction. Matches iff non-empty.
* Examples: `up 1 d4`=d5; `up d4`=d5-8; `up 1 3 d4`=d5-7; `up -2 d4`=d2; `right -1 1 d4`=c-e4;
  `left [d4,e5]`=[a-c4,a-d5]; `vertical 3 d4`=[d7,d1]; `diagonal 1 d4`=[e5,c5,c3,e3];
  `horizontal 0 1 d4`=c-e4; `orthogonal d4` = rook lines of d4; `flip up 2 right 1 ♕` = knight hops;
  `diagonal diagonal h1` = light squares; `diagonal 0 7 diagonal 0 7 a1` = dark squares.
* Direction keywords are also `ray`'s optional parameter (§5.5).
* ⚠️ AMBIGUOUS: `up 1 x` when x is a Num variable vs Set variable — resolve by the variable's static
  type (Num → range element, Set → argument).

### 5.7 `light`, `dark`

`light S` / `dark S` (P20): Set = members of S on light / dark squares. `light ♗>1` (two light-square
bishops), `light ◭ == ◭` (all pieces on light squares).

### 5.8 `file`, `rank`, `makesquare`

| Filter | Arg (prec.) | Result | Fails when |
|---|---|---|---|
| `file S` | Set (P14) | Num 1–8 (a=1 … h=8) | S doesn't contain exactly one square |
| `rank S` | Set (P14) | Num 1–8 | same |
| `makesquare (f r)` | Num Num (P8 each) | Set {square(f,r)} | either fails or ∉ 1…8 |
| `makesquare S` | Str (P8, absorbs `+`) | Set | string isn't exactly `[a-h][1-8]` |

* `file`/`rank`/`makesquare` results are not themselves transformed by transforms, but their arguments
  are (`{flip makesquare "b4"} == b4`; `{flip makesquare (2 4)} == b4` because numbers don't
  transform; a square designator argument does).
* ⚠️ AMBIGUOUS (doc typos): `b4 == makesquare (2 8)` (should be `(2 4)`); `{flip makesquare b4}` with a
  Set argument is not a defined form; the "equivalent" expansion contains `ascii x[1]= ascii "1"` (should
  be `-`).

### 5.9 Piece identity filters

All take a Set argument at P14 and **fail unless the set has exactly one square**.

| Filter | Result | Values / notes |
|---|---|---|
| `type S` | Num | empty 0, pawn 1, knight 2, bishop 3, rook 4, queen 5, king 6 |
| `colortype S` (deprecated) | Num | 0 empty; `+type` white; `-type` black |
| `typename S` | Str | one of `R N B Q K P _` |
| `piecename S` | Str | one of `R B N Q K P r b n q k p _` (never Unicode) |
| `pieceid S` | Num | id of the piece on the square; **also fails if the square is empty** |
| `power S` | Num | Σ material over pieces in S: P1 N3 B3 R5 Q9 K0 empty 0 (never fails) |

Piece ids are unique per game and stable across moves and promotion (`pieceid Mismatch ==
source:pieceid Mismatch`). Examples: `power △ ≥ 15`, `power A * 3 < power a`, `typename to in "RNB"`.

### 5.10 Pawn-structure filters (Set, no arguments, unaffected by enclosing transforms)

| Filter | Definition (both colours) |
|---|---|
| `passedpawns` | `notransform ⬓{ ♙ & ~down horizontal 0 1 ♟ }` — pawns with no enemy pawn ahead on own/adjacent files |
| `doubledpawns` | `notransform ⬓{ ♙ & vertical ♙ }` — pawns sharing a file with a friendly pawn |
| `isolatedpawns` | `notransform ♙♟ & ~⬓{ ♙ & horizontal 1 vertical 0 7 ♙ }` — pawns with no friendly pawn on an adjacent file |
| `connectedpawns` | `notransform ⬓{ ♙ & horizontal 1 vertical 0 7 ♙ }` — pawns with a friendly pawn on an adjacent file (any rank); start position → all 16 |

(The isolatedpawns page says "contain doubled pawns" — typo.)

### 5.11 `#`, `fen`, constants

**`#X`** (Num; P9, always matches when X matches):

| X | Value |
|---|---|
| Set | cardinality (`#K`, `#[Kk]`, `#P attackedby K`) |
| Str | length (`#"Capablanca" == 10`) |
| Dictionary name | number of entries |

**`fen`**

| Form | Type | Semantics |
|---|---|---|
| `fen` | Str | FEN of the current position; halfmove clock forced to 0 and fullmove number to 1; castling/en-passant privileges from the PGN `FEN` header are disregarded |
| `fen "<fen>"` | Logical | matches iff the board placement equals the **first field** of the given FEN (other fields ignored, may be omitted) |

* Extended placement chars in the argument: `A` any white piece, `a` any black piece, `_` empty,
  `.` anything; digits and standard letters as usual. Example `fen "Aa._kbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"`.
* `fen "…"` can be flipped/rotated but not shifted (sibling doc).
* Not an implicit-search filter, but in `str/message/comment` arg lists `fen "x"` parses as two args.
* ⚠️ AMBIGUOUS: the `EditFen` sample uses `assert F[-3:]="0 1"` (assignment, not `==`) — doc typo.

**Constants**: number literals (§1.5); `[]` (∅); `▦`/`.`; `true`/`false`; `white`/`black`.

---

## 6. Game metadata filters

| Filter | Syntax | Type | Value | Fails when |
|---|---|---|---|---|
| `tag` | `tag "Name"` (non-empty literal, case-sensitive) | Str | value of that PGN tag | tag absent. **Not supported**: `"FEN"`, `"Round"`, `"Result"`, and any name starting with `White`/`Black` other than exactly `"White"`/`"Black"` |
| `player` | `player` | Str | `White` + `\n` + `Black` | |
| `player white` / `player black` | | Str | `White` / `Black` tag | |
| `event` | `event` | Str | `Event` tag | |
| `site` | `site` | Str | `Site` tag | |
| `date` | `date` | Str | `Date` (`yyyy.mm.dd`, `?` allowed) | |
| `eventdate` | `eventdate` | Str | `EventDate` | |
| `eco` | `eco` | Str | `ECO` | |
| `elo` | `elo [white\|black]` | Num | that player's Elo; bare `elo` = max of both | relevant Elo missing/unknown |
| `year` | `year` | Num | year of the game (from `Date`) | unknown/missing |
| `result` | `result 1-0` \| `0-1` \| `1/2-1/2` | Logical | — | game result differs |
| `gamenumber` | `gamenumber` | Num | 1-based number of the game being examined | |
| `lastgamenumber` | `lastgamenumber` | Num | game number of the last game that will be examined (respects `-gamenumber`/header range; heuristic, experimental) | |

**Implicit search parameter.** For the string tag filters (`player`, `player white`, `player black`,
`event`, `site`, `date`, `eventdate`, string-valued `hhdb` filters, and — per the filter table —
`eco`): `F "lit"` ≡ `"lit" in F` (literal substring, **no regex**). E.g. `player "Kasparov"` ≡
`player white "Kasparov" or player black "Kasparov"`; `site "Zee"`. Use `~~` for regexes:
`player black ~~ "Fi[sch]+er"`, `date ~~ "198\d\.10\..."`.
Exception: inside `str`/`message`/`comment` argument lists the literal is a separate argument (§4.13).
`originalcomment "…"` is similar but treats NAG literals specially (sibling doc).

Notes:
* Missing string tags: ⚠️ AMBIGUOUS — whether `event`/`site`/… fail or yield `""` when the tag is
  absent is unspecified (only `tag` is documented to fail). Recommend: fail.
* Transforms: `⬓`/`flipcolor` swaps `player white`↔`player black`, `elo white`↔`elo black`,
  `result 1-0`↔`0-1` (e.g. `⬓{player white "Ivanchuk" result 1-0}` = Ivanchuk wins).
* `year` ≡ `int` of the first 4 digits of `Date` (example: `date ~~ "(\d{4})\.(\d{2})\.(\d{2})" Year = int \1`).
* Dates sort chronologically as strings (`sort "Date" date`).
* Command-line counterparts (`-player`, `-white`, `-black`, `-event`, `-site`, `-year range`,
  `-gamenumber range`, `-elo`, `-result`) — sibling doc / CLI.
* ⚠️ AMBIGUOUS: `result` argument — result page shows bare `result 1-0`, filter table shows
  `result "1-0"`. Recommend accepting both; `*` (unfinished) unsupported. Lexer: reassemble
  `1 - 0`, `0 - 1`, `1 / 2 - 1 / 2` after `result`.
* ⚠️ AMBIGUOUS: the tag-query table names the White/Black filters `white`/`black` and the implicit-search
  list includes bare `white`, `black` (and a CLI example `-cql 'white~~ "Bog.*ov"'`), but `white`/`black`
  are numeric constants. Recommend: only `player white` / `player black` are tag filters; bare
  `white`/`black` are always Num constants.
* ⚠️ AMBIGUOUS: `elo` with no colour when only one Elo is known — max of known, or fail? Recommend fail
  only if both unknown.

---

## 7. Ambiguity register (summary)

| # | Topic | Issue | Recommendation |
|---|---|---|---|
| A1 | Unicode table | `▲` codepoint and `→`/`←` codepoints/ASCII swapped | `▲`=U+25B2=`a`; `→`=U+2192=`->`; `←`=U+2190=`<-` |
| A2 | Comments | `/* */` nesting; comments inside strings | no nesting; literal inside strings |
| A3 | Strings | multi-line literals; multi-digit `\10` | allow both |
| A4 | Identifiers | leading digit allowed? | no |
| A5 | Designators | `Qu`, bracket-less `Aa`, mixed ASCII/Unicode inside `[...]`, reversed ranges | reject `Qu`/`Aa`; allow mixing; reject reversed |
| A6 | `[` | `Dict[a3]` vs "`[a2]` is always a designator" | designator wins; require `D[ a3 ]` (or dictionary-aware lexing) |
| A7 | `K∊E`, `R∊F` | designator-shaped iteration variable names | doc error; reject |
| A8 | Set `<` Set | undefined | compare cardinalities or reject |
| A9 | `sqrt #♜ + #♛` example | contradicts numeric-arg rule | follow rule: `sqrt(#♜+#♛)` |
| A10 | unary `-` | listed at two precedence levels | conventional (P12) |
| A11 | `~~` precedence | table says tighter than `+`; examples say `X+Y~~p` ≡ `(X+Y)~~p` | follow examples |
| A12 | `not … or …` | compound page contradicts table | follow table |
| A13 | `#` arg level | "below `|`" vs table P9 | P9 + type-directed extension |
| A14 | Missing from table | `=` RHS, `str X`, `assert`, `∊` domain, `while`, `isbound` | see §3.5 |
| A15 | Type-directed parsing | needed for `ascii 65 + "C"`, `int "32"+1`, `position 0 : child` | implement absorption only when type-valid |
| A16 | Assignment value | unspecified | Logical |
| A17 | `x[2:2]="This"` example | wrong result in docs | implement rule |
| A18 | Dictionary iteration | match/value/order | matches iff body matched for some key; insertion order |
| A19 | `dictionary E["1"]=="2"` | `==` vs `=` | typo |
| A20 | Functions | define-before-use, scope, shadowing; `function square(x)` example | top-level, define-before-use; reject keyword names |
| A21 | `loop` match wording | "ever true" vs "evaluated more than once" | body matched ≥ 1 time |
| A22 | `◭x∊` ASCII | undocumented | accept `piece x in S B` |
| A23 | Iteration var shadowing | unspecified | allow same kind; restore after |
| A24 | Pos `==` Pos; Str vs Num compare | unspecified | identity; reject |
| A25 | `/`, `%` negatives; overflow | unspecified | Swift truncation; trap/wrap decision TBD |
| A26 | `str` output formats | multi-square Set format; piece-var glyph | `[a1,h1]`; ASCII letter |
| A27 | `~~` | non-literal patterns; capture state before match; `^`/`$` multiline; empty-match loop; mutating target in `while` | literal only; fail; non-multiline; ECMAScript advance; snapshot |
| A28 | `→` chains | order/distinctness; mixed `→`/`←`; claimed equivalence with `pin` | ordered+distinct; reject mixed; arrows colour-agnostic |
| A29 | `ray` value | "terminate" = first or last square | last square |
| A30 | puremate | "refutation square … white king"; "guarded once by a necessary pin"; "checking a square adjacent" | see §5.3 |
| A31 | purestalemate | rules 3 and 4 identical | pinned adjacent black piece may be attacked once, by its pinner |
| A32 | `makesquare` page | `(2 8)` typo; `makesquare b4` with Set; `= ascii "1"` | typos |
| A33 | `fen` sample | `assert F[-3:]="0 1"` | typo for `==` |
| A34 | Direction range vs set var | `up 1 x` | resolve by static type |
| A35 | Tag filters | absent tag → fail or `""`; bare `white`/`black` as tag filters; `result` quoted vs bare; `elo` with one Elo missing | fail; Num constants only; accept both; fail only if both missing |
| A36 | `eco` implicit search | in filter table, not in implicit-search list | treat as implicit search |
| A37 | Assignment RHS precedence | not specified | parse at P6+ (absorb relational/arith) |
