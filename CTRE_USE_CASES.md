# CTRE use cases — compile-time regex in the wild

Deep-research study (multi-source, adversarially verified: 17 sources fetched, 62 claims
extracted, 25 verified by 3-vote, 22 confirmed / 3 refuted). Companion to
[REGEX_USE_CASES.md](REGEX_USE_CASES.md). Scope: **CTRE** (Compile-Time Regular
Expressions for C++, Hana Dusíková) — the closest real-world analog to zeetah's comptime
`Pattern` path. Goal: validate and maybe extend the benchmark for the **compile-time**
side.

> **Bottom line:** CTRE is a **static-pattern-only** engine by language construction — the
> pattern is a non-type template parameter (`ctll::fixed_string`), so it *cannot* be built
> at runtime; only the subject is dynamic. This is strong external confirmation that a
> compile-time regex path serves the **static-literal majority** of authored regexes. The
> existing 53-pattern suite already covers nearly all of CTRE's idiomatic pattern shapes;
> the genuine gaps are about **API entry points** (`search_all` iteration, `starts_with`
> prefix, `split`) more than about pattern syntax.

---

## 1. Static vs dynamic — the defining fact (HIGH confidence, unanimous)

CTRE patterns are **necessarily compile-time literals**. The pattern is passed as a
non-type template parameter via `ctll::fixed_string`; by C++ language rule it must be a
compile-time constant. There are exactly three documented supply syntaxes:

```cpp
ctre::match<"h.*">(subject);                                   // C++20 NTTP literal
static constexpr auto p = ctll::fixed_string{"h.*"};           // C++17 form
"h.*"_ctre.match(subject);                                     // UDL form
```

- The "compile-time **or** runtime" tagline refers to the **subject**, not the pattern.
  Matching/searching/capturing can run at either phase (`static_assert` demos prove full
  compile-time evaluation), but the pattern is *always* static.
- **No runtime pattern construction exists.** Teams that need dynamic patterns fall back to
  a runtime engine (`std::regex` / RE2 / PCRE2). Confirmed by upstream issue #335 (a user
  migrating `std::regex_match` automotive/CAN parsing: *"I know the regex patterns at
  compile time but not the search strings"*) — the canonical CTRE fit verbatim. The
  separate **CTVE** library exists precisely to build patterns at compile time, reinforcing
  that pattern-building is out of CTRE's scope.

*Sources: readthedocs api.html, README, WG21 P1433R0 (author), Meeting C++ 2019 slides,
DeepWiki, issue #335 — all 3-0.*

**Implication for zeetah:** every CTRE pattern in real code maps to zeetah's comptime
`Pattern("…")`, never to runtime `Regex.compile`. The benchmark's `zeetah-dfa` (comptime)
harness is the correct apples-to-apples peer for CTRE; the runtime `zeetah` harness has no
CTRE analog.

---

## 2. API surface — entry points matter more than patterns (HIGH confidence)

CTRE exposes **six primary functors**, all taking the pattern as a template argument:

| Functor | Meaning | Benchmark model analog |
|---|---|---|
| `ctre::match` | whole input must match | (anchored) `count` |
| `ctre::search` | match somewhere within | `count` / `grep` |
| `ctre::starts_with` | prefix match | *(no analog — see gaps)* |
| `ctre::range` / `ctre::search_all` | iterate all matches | `count` / `count-spans` |
| `ctre::tokenize` | lexer-style tokenization | `count-spans` |
| `ctre::split` | split on pattern | *(no analog — see gaps)* |

Idiomatic capture extraction is via **C++ structured bindings**, the single most concrete
real-world pattern category:

```cpp
auto [whole, y, m, d] = ctre::match<"([0-9]{4})/([0-9]{2})/([0-9]{2})">(input);
```

Named captures `(?<name>...)` are supported. The benchmark's `count-captures` model is the
right peer for this idiom.

*Sources: README "Basic API", api.html, author slides — match/search/starts_with/range/
tokenize/split all 3-0.*

---

## 3. Capability limits that shape real CTRE patterns (HIGH confidence — corrected)

**Supported** (verified, several initially-doubted): back-references (`\g{N}`, `\1`..`\9`),
multiline (`multiline_` functions), **Unicode properties + UTF-8** (via
`<ctre-unicode.hpp>`), and **lookbehind** (PR #258, merged 2022-06-01 — *"the holy grail of
CTRE done"*).

**Not supported** (README "most of PCRE with a few exceptions"): callouts, comments,
conditional patterns, control chars `\cX`, match-point reset `\K`, named characters, octal
numbers, **options/modes (inline flags like `(?i:…)`)**, subroutines/recursion, Unicode
grapheme clusters `\X`.

> ⚠️ **Refuted overreaches** (don't repeat these — they failed verification 0-3 / 0-3 / 1-2):
> CTRE does **not** lack Unicode property classes (it has them via `ctre-unicode.hpp`), and
> the inline-flag limitation should be cited only from the README **"options/modes"** line,
> *not* characterized from the readthedocs syntax page.

**This explains the build failures we already hit in the suite** (see
[c-cpp-engines.md memory] and `benchmarks.json` `skip_engines`):
- `sqli_nested` uses `(?i:…)` → **inline flag = unsupported "options/modes"** → CTRE build
  error. ✓ matches finding. (Correctly skipped.)
- `fqdn` uses `(?m)` + nested quantifier → the `(?m)` inline flag is the unsupported piece.
  ✓ matches finding. (Correctly skipped.)

So both CTRE skips in the suite are explained by **one** documented limitation: inline
mode flags. Multiline itself is fine via the `multiline_*` functions / `ctre::multiline`
modifier — the issue is the embedded `(?m)`/`(?i:)` *syntax*, which the harness already
handles by emitting `ctre::multiline` as a modifier for `multiline:true` workloads.

---

## 4. Who uses CTRE — named adopters (live code search, 2026-06)

A direct pass over **Sourcegraph's public code index** (`ctre::match<` / `search<` /
`starts_with<` / `split<` plus pattern definitions; 44 repos touched) produced the roster
the doc-level pass couldn't. Ranked by how central regex is to the project:

| Domain | Named adopters | What they compile with CTRE |
|---|---|---|
| **Lexers / parsers** (dominant) | `marekjm/viuavm` (VM assembler — a *whole token table*), `aappleby/matcheroni` (parser-combinator lib), `compiler-explorer/asm-parser`, `greg7mdp/gdbf` (GDB frontend) | keyword-with-boundary `\.text\b`; number literals `-?0x[0-9a-f]('?[0-9a-f]+)*u?`, `-?(?:0\|[1-9](?:'?[0-9]+)*)u?`; identifiers; punctuation tokens; email/URL/IPv4 |
| **Databases** | `ad-freiburg/qlever` (834★ SPARQL engine), `memgraph/memgraph` (graph DB) | log-line `ctre::match<kPattern>`; URL scheme dispatch `(https?\|ftp)://`, `s3://` |
| **Bioinformatics** | `ncbi/ncbi-cxx-toolkit-public` (NCBI C++ Toolkit) | `(micro\|mini\|)satellite` (satellite-DNA classification) |
| **Tooling / ISA** | `riscv/riscv-unified-db` | semver `(([0-9]+)(?:\.([0-9]+)(?:\.([0-9]+)(?:-(pre))?)?)?)` |
| **Image / SVG** | `SaltyAom/wasm-image-optimization` | XML attr `([\w\-]+)\s*=\s*"([^"]*)"`; tag+capture `<feDropShadow([^>]*?)/?>`; base64 data-URI |
| **Config / CLI** | `CachyOS/New-Cli-Installer` | key=value `[a-zA-Z]*=[a-zA-Z0-9]*` |
| **Gaming** | `gwdevhub/GWToolboxpp` (Guild Wars 2), `razaqq/PotatoAlert` (WoWs), `LiteLDev/LeviLamina` (Minecraft) | (call sites confirmed; patterns mostly named constants) |
| **Misc / search-all** | `pt`, others | `([0-9]+),?` (number-list iteration), `\p{Letter}+` (Unicode property) |

**The clear #1 domain is lexing/tokenizing** — programming languages, assembly, and
protocols. That fits CTRE's design exactly: a lexer's token set is fixed at compile time, so
every token regex is a static literal, and CTRE compiles the whole table to branch-free
code. `viuavm` and `matcheroni` are the archetypes.

Also evidenced (from the doc-level pass): **embedded / constrained C++** — CTRE matches on
the stack, no heap, no exceptions (vs `std::regex` which heap-allocates and throws); a
trivial `[0-9]+` is ~40 lines of assembly. Countervailing cost: long compile times
(issue #78: 22-min debug build). And the canonical static/dynamic split is documented
verbatim in issue #335 (automotive/CAN parsing migrating off `std::regex`).

---

## 5. Coverage gaps vs the current 53 — measured

CTRE's *idiomatic patterns* are already well covered. Mapping the canonical CTRE examples
onto the existing suite:

| CTRE-canonical pattern / idiom | Already in suite as |
|---|---|
| date capture `([0-9]{4})/([0-9]{2})/([0-9]{2})` | `date_capture` (ISO, dashes) ✓ |
| integer `[0-9]+` | `digits` ✓ |
| alternation `aloha\|[a-z]+` | `alternation` ✓ |
| named-capture extraction `(?<name>…)` | `grok_named`, `querystring_kv` ✓ |
| back-reference `\g{N}` / `\1` | `backref_word` ✓ |
| lookbehind | `lookbehind_dollar`, `querystring_kv` ✓ |
| Unicode property | `unicode_property` ✓ |
| multiline anchored | `multiline_log`, the `^…$` validators ✓ |
| CSV field | `csv_field` ✓ |

**The real gap is API entry points, not pattern syntax.** Three CTRE idioms have no model
analog today:

1. **`search_all` number/CSV iteration** — `([0-9]+),?` over a comma-separated number list.
   This is *the* canonical README range example and a distinct iteration workload. **Static.**
   Closest existing peer is `csv_field`, but the comma-list-of-numbers shape is its own
   common case (sensor logs, vectors, telemetry).
2. **`starts_with` (prefix match)** — a distinct API entry point with no benchmark model.
   Adding a `starts-with` model (anchored-at-start, non-anchored-at-end) would let CTRE,
   zeetah-comptime, and RE2 be compared on prefix dispatch (common in protocol/CLI parsing).
   **Static.**
3. **`split` / `tokenize`** — CTRE has first-class `split`; the suite has no split model.
   Lexer-style tokenization is partially covered by `nltk_tokenizer` / `bpe_tokenizer`
   under `count-spans`, so this is lower priority. **Static.**

### Implemented (53 → 56), each backed by a named real-world CTRE adopter

The live-code-search pass turned the gap list from speculative into evidenced. Three
workloads were added — all **static / comptime-eligible**, all confirmed in real CTRE code,
each filling a distinct gap:

1. **`numlist_iter`** = `([0-9]+),?` — the canonical CTRE `search_all` number-list idiom
   (README example; seen in `pt`). Tests optional-suffix iteration / span boundaries.
2. **`cpp_int_literal`** =
   `-?(?:0[xX][0-9A-Fa-f](?:'?[0-9A-Fa-f]+)*|0[bB][01](?:'?[01]+)*|[0-9](?:'?[0-9]+)*)[uU]?`
   — a programming-language **lexer** integer token (hex/binary/decimal, C++14 `'` digit
   separators, optional sign & `u` suffix), modeled on `viuavm`'s real token table. Tests
   base-prefix **alternation dispatch** — the core lexer job. `0xDEAD` matches as one token
   here vs. `[0-9]+` splitting it, so it is genuinely distinct from `digits`.
3. **`xml_attr`** = `([\w\-]+)\s*=\s*"([^"]*)"` — XML/SVG attribute key-value extraction with
   two captures (`wasm-image-optimization`). Distinct from `querystring_kv` (no lookbehind)
   and `html_tag`/`href`. Capture groups are *not* wrapped around an alternation, so it
   sidesteps the [[zeetah-vm-capture-alternation-bug]].

Corpus (`gen_corpus.py`) extended: a comma-separated number-list token and hex/bin/dec
literal tokens with `'` separators woven into normal lines; `xml_attr` reuses the existing
`class="…"` / `href="…"` attribute tokens. zeetah comptime counts match Python `re` exactly
(113831 / 111224 / 3157) and the patterns compile with no DFA blowup.

### Considered, not added
- **`starts_with` model** — a real CTRE entry point (prefix dispatch, e.g. memgraph's URL
  schemes) with no benchmark analog, but adding it means new model wiring across 15
  harnesses; deferred unless prefix matching becomes a target.
- **`split` / `tokenize` model** — covered indirectly by `count-spans` on the tokenizer
  workloads; low marginal signal.
- Patterns that only re-exercise CTRE syntax already covered (date capture, email, IPv4,
  Unicode property, semver) — skipped to avoid inflating the suite without new signal.

---

### Measured outcome (56-pattern gate PASSED, count @ 1 MiB)

The new workloads land where the research predicted — and validate the comptime thesis hard:

| Workload | #1 | #2 | zeetah-dfa rank | Note |
|---|---|---|---|---|
| `numlist_iter` | **ctre** (1.0×) | **zeetah-dfa** (1.3×) | 2 / 15 | both compile-time engines beat pcre2-jit (1.5×) |
| `cpp_int_literal` | **ctre** (1.0×) | **zeetah-dfa** (1.1×) | 2 / 13 | comptime engines top-2; pcre2-jit 1.3× |
| `xml_attr` | pcre2-jit (1.0×) | re2 (1.1×) | 6 / 14 | captures+backtracking: **zeetah beats ctre** (2.6× vs 7.5×) |

**The headline:** on the two lexer/DFA-eligible patterns (CTRE's real-world sweet spot),
**CTRE and zeetah-dfa take ranks 1–2 and both beat PCRE2-JIT** — zeetah-dfa is within 1.1×
of CTRE on the `viuavm`-style integer-literal token. On capture-heavy attribute extraction
(`xml_attr`), CTRE's compile-time model is *not* its strength: it drops to 7.5× and both
zeetah paths beat it. Gate semantics: all 14 gated engines agree; `posix` (gate-exempt)
reports 0 because `\w`/`\s` aren't POSIX, and `mvzr`/`posix` reject `cpp_int_literal`
(non-capturing groups / `?` — expected).

## 6. Net conclusion

1. **Validates the comptime emphasis.** CTRE proves the compile-time-regex value
   proposition is real and static-only — exactly zeetah's comptime `Pattern` niche. The
   right CTRE peer in the suite is `zeetah-dfa`, not runtime `zeetah`.
2. **Existing CTRE skips are explained by one limitation** (inline mode flags `(?i:)` /
   `(?m)` syntax), already correctly handled in `benchmarks.json`.
3. **Pattern coverage is essentially complete**; the only worthwhile *pattern* addition is
   `([0-9]+),?` (search_all iteration). The bigger untapped axis is **API entry points**
   (`starts_with`, `split`), which is a *model* question, not a pattern question.
4. **Weak spot, stated plainly:** no evidence-backed roster of named CTRE adopters; embedded
   C++ is the headline domain but census-level frequency data was not obtainable.

*Refuted claims and full source list retained in the research transcript; key refutations:
CTRE *does* support Unicode properties and the inline-flag limit is the only thing blocking
`(?i:)`/`(?m)` syntax.*
