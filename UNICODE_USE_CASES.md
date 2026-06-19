# Unicode use cases — what zeetah's missing Unicode features are actually for

Deep-research study (multi-source, adversarially verified: 20 sources fetched, 88 claims
extracted, 25 verified by 3-vote, **25 confirmed / 0 refuted**; 102 agents). Companion to
[REGEX_USE_CASES.md](REGEX_USE_CASES.md) and [CTRE_USE_CASES.md](CTRE_USE_CASES.md). Scope:
the eight Unicode regex features zeetah's byte-oriented engine currently lacks or only
partially supports — what real applications need them, and which Unicode conformance tier
each sits in.

> **Bottom line:** The Unicode Consortium formalizes regex Unicode support as a **tiered
> conformance model** ([UTS #18](https://www.unicode.org/reports/tr18/)). Six of zeetah's
> eight gaps fail **Level 1 (Basic)** — the *baseline* tier, not the advanced one — because
> a byte engine where `.` matches one UTF-8 byte instead of one code point fails Level 1's
> defining requirement ("Unicode characters as basic logical units"). The strongest
> must-have driver is **security**: homograph / IDN-spoofing detection chains together
> script properties, normalization, and case folding, and the standards
> ([UTS #46](https://unicode.org/reports/tr46/), [UTS #39](https://www.unicode.org/reports/tr39/),
> [UTR #36](http://www.unicode.org/reports/tr36/tr36-10.html)) make these mandatory for
> browsers, registrars, and input-validation layers.

---

## Conformance tier overview

| Tier | Requires | zeetah status |
|------|----------|---------------|
| **Level 1 (Basic)** | code-point-as-unit `.`; script/binary properties (RL1.2); set operations (RL1.3); simple case folding (RL1.5); Unicode line boundaries + `\R` (RL1.6) | **multiple gaps** |
| **Level 2 (Extended)** | `\X` grapheme clusters (RL2.2); full case folding ß→SS (RL2.4); canonical equivalence | not started |

Source: [UTS #18 Unicode Regular Expressions](https://www.unicode.org/reports/tr18/). The
benchmarked reference engine for shipped behavior is **PCRE2**
([pcre2pattern](https://pcre2project.github.io/pcre2/doc/pcre2pattern/)); only PCRE2 was
directly verified here (see caveats).

---

## 1. Property escapes beyond Latin-1 — `\p{Greek}`, `\p{Han}`, `\p{Emoji}`, `\p{Alphabetic}` (HIGH)

**Tier:** scripts + binary = Level 1 (RL1.2); Emoji properties = Level 2 (RL2.7).
**zeetah today:** resolves `\p{...}` to a Latin-1 byte set only — everything above U+00FF is
silently dropped.

UTS #18 RL1.2 mandates a minimal property list (General_Category, Script,
Script_Extensions, Alphabetic, Uppercase, Lowercase, White_Space). PCRE2 ships the full set
(script names, general category, Bidi_Class, binary yes/no properties via `\p{xx}`/`\P{xx}`).

**Who hits this:** search engines; **source-code tokenizers / linters / compilers** —
modern identifier rules use `\p{Alphabetic}`/`\p{L}` (JS, Rust, Swift, Java all permit
Unicode identifiers); i18n / localization tooling; any non-Latin text processing.

## 2. Full + simple case folding — Greek ς, German ß↔ss, Turkish ı/İ, Cyrillic (HIGH)

**Tier:** simple 1:1 folding = Level 1 (RL1.5); full 1:n folding (ß→SS) = Level 2 (RL2.4).
**zeetah today:** folds only `a-z ↔ A-Z`.

Production case folding is required by **IDN/domain validation**: UTS #46 derives its
character mapping from the `NFKC_Casefold` property, and German ß (U+00DF) / Greek final
sigma ς (U+03C2) are named **"Deviation characters"** whose IDNA2003-vs-IDNA2008
disagreement "result[s] in potential for security exploits" (e.g. `sparkasse-gießen.de`
phishing).

**Who hits this:** domain registrars & browsers (IDNA); i18n search (case-insensitive
search over non-English content is broken without it); security/input-validation layers.

> **Standard caveat:** recent UTS #18 revisions **retracted** the full case-*insensitive
> matching* requirement (backreference difficulty) while **keeping** the full
> case-*folding* requirement.

## 3. Extended grapheme clusters `\X` — emoji ZWJ, skin tones, flags, Devanagari, Hangul (HIGH)

**Tier:** Level 2 (RL2.2), per [UAX #29](https://www.unicode.org/reports/tr29/).
**zeetah today:** unimplemented.

The unit is the UAX #29 extended grapheme cluster: emoji ZWJ sequences stay unbroken
(GB11), skin-tone modifiers attach (GB9), regional-indicator flag pairs do not split
(GB12/13), Indic/Devanagari spacing vowel signs attach (GB9a), Hangul L+V+T form one
cluster (GB6-8). **The rules are mechanically convertible to a regex/DFA** — relevant to
zeetah's architecture. PCRE2 implements `\X` exactly per UAX #29.

**Who must-have this:** terminal emulators (cursor advance / cell width —
[grapheme-clusters-in-terminals](https://mitchellh.com/writing/grapheme-clusters-in-terminals));
text editors (cursor movement, backspace deleting one 👨‍👩‍👧 not one code point);
chat/messaging apps (emoji); i18n text segmentation; CJK/Indic/Hangul processing.

> **Version caveat:** UAX #29 added GB9c (Indic conjunct break) in Unicode 15.1. Any `\X`
> implementation is pinned to a specific Unicode data version.

## 4. Unicode-aware `\w` / `\b` / `\d` for CJK, Cyrillic, Arabic, Thai (HIGH)

**Tier:** Level 1 (depends on RL1.2 properties).
**zeetah today:** `\w`/`\b`/`\d` are ASCII-only — they **silently mis-segment** all
non-Latin text.

PCRE2 with `PCRE2_UCP` redefines `\d`→`\p{Nd}`, `\s`→`\p{Z}|\h|\v`,
`\w`→`\p{L}|\p{N}|\p{Mn}|\p{Pc}`, and consequently `\b`/`\B` (defined in terms of `\w`/`\W`).

**Who hits this:** search engines & tokenizers (Elasticsearch, Meilisearch script-based
tokenizers); log processing; text analytics over CJK/Cyrillic/Arabic/Thai. This is the
classic "works on English, breaks on everything else" gap.

## 5. Normalization (NFC/NFD/NFKC/NFKD) × matching (HIGH)

**Tier:** Level 2 (canonical equivalence).
**zeetah today:** none.

UTS #46 IDNA mandates normalizing domains to NFC. UTR #36 confirms normalization +
casefolding collapse *some* spoofs (a + combining umlaut → ä) but warns "visual spoofing
can still occur with many IDNs" and they "do not handle single-script confusables" —
necessary but insufficient.

**Who hits this:** IDN/domain validation (mandatory pre-step); search (decomposed vs
precomposed `é` must match); bioinformatics / financial text parsing; any system comparing
user-supplied Unicode.

## 6. Code-point-granular `.` (HIGH)

**Tier:** *the* defining Level 1 requirement ("the regex engine provides support for
Unicode characters as basic logical units").
**zeetah today:** byte-oriented — `.` matches one UTF-8 byte, so `é` is 3 matches.

**Who hits this:** essentially every UTF-8 text app where `.` must mean "one character" —
editors, search, log processing, `.{3}` length checks.

## 7. Character-class set operations — `[\p{L}--\p{Lu}]`, `&&`, `~~` (HIGH)

**Tier:** Level 1 (RL1.3), with an explicit conformance carve-out confirming it is
otherwise required.
**zeetah today:** unimplemented.

UTS #18 recommends `||` (union), `&&` (intersection), `--` (difference), `~~` (symmetric
difference). **Set-difference cannot be replaced by `[^...]`** (which is code-point
complement). Examples: `[\p{L}--[QW]]`, `[\p{script=Grek}&&\p{uppercase}]`.

**Who hits this:** source-code tokenizers/linters/compilers ("letters except uppercase",
"Greek uppercase"); i18n class composition. JS's newer `/v` flag exists specifically to add
this.

## 8. Unicode line separators — U+0085 NEL, U+2028, U+2029, and `\R` (HIGH)

**Tier:** Level 1 (RL1.6).
**zeetah today:** `\R` handles Latin-1 NEL (0x85) but not the multibyte U+2028/U+2029.

RL1.6 requires line-boundary handling to recognize CRLF, LF, CR, **plus NEL, LINE
SEPARATOR (U+2028), PARAGRAPH SEPARATOR (U+2029)**; `\R` is the strongly-recommended
metacharacter for all of them.

**Who hits this:** log processing; text editors; terminal emulators; compilers/tokenizers.
Notably a historical **JS/JSON security hazard** — U+2028/U+2029 were unescaped line
terminators in JS string literals pre-ES2019.

---

## The security through-line (strongest must-have story)

Homograph / IDN spoofing is the most defensible "real applications need this" case, and it
chains three of the gaps:

- **Why it exists:** visually confusable characters are deliberately *not* unified across
  scripts ([UTR #36](http://www.unicode.org/reports/tr36/tr36-10.html)) — Greek omicron,
  Cyrillic о/с, Latin o/c are distinct code points, so `pаypal.com` (Cyrillic а) is a
  different string that looks identical.
- **What the standards say:** [UTS #46](https://unicode.org/reports/tr46/) states IDNA
  "do[es] not address security problems associated with confusables (the so-called
  paypal.com problem)" and delegates to [UTS #39](https://www.unicode.org/reports/tr39/),
  which defines: two strings are confusable iff `skeleton(X) = skeleton(Y)`, distinguishing
  **mixed-script** from **whole-script** confusables (Cyrillic `ѕсоре` passing as Latin
  `scope`).
- **Features required:** script properties (`\p{Cyrillic}` for mixed-script detection) +
  NFC/NFKC normalization + case folding (NFKC_Casefold).
- **Who must-have it:** browsers, registrars, anti-phishing, identifier/input-validation,
  and source-code identifier linters (Trojan-Source-style attacks).

---

## Must-have vs nice-to-have

- **Must-have for internationalized OR security-sensitive apps:** Level 1 properties, set
  operations, Unicode line boundaries, code-point `.`, Unicode `\w`/`\b`, plus the
  normalization + case-folding + confusable security stack. Without these, the engine is
  "ASCII-only that tolerates UTF-8 bytes."
- **Must-have specifically for emoji/segmentation/editing workloads:** `\X` grapheme
  clusters (terminals, editors, chat). Nice-to-have elsewhere.

---

## Open questions (for zeetah planning)

1. **Which gaps fit the byte-oriented model without a code-point/decoder rearchitecture?**
   Level 1 `\p{Script}` and code-point `.` *can* be lowered to UTF-8 byte-range sequences
   (zeetah already does this for Latin-1 `\p{...}`). Harder: full case folding and `\X`
   (cross-byte state). This is the natural feasibility question for the reserved `(?u)` mode.
2. **Which Unicode data version to target?** `\X` (UAX #29) and property tables change per
   release; UTS #39 confusable data updates independently.
3. **Is the demand empirical for zeetah's users, or purely conformance-driven?** Do the
   benchmark workloads actually exercise i18n/security inputs, or are these gaps latent?

---

## Caveats on the research

- All normative claims are 3-0 verified against **primary** Unicode standards (UTS #18,
  UAX #29, UTS #46, UTS #39, UTR #36) + primary PCRE2 docs.
- **Only PCRE2 was directly verified** among engines. Cross-engine specifics (RE2, Rust
  `regex`, V8 `/u` vs `/v`, .NET, Java, Python `regex`, Oniguruma) were not individually
  verified — though Rust regex's
  [UNICODE.md](https://github.com/rust-lang/regex/blob/master/UNICODE.md) documents its own
  UTS #18 conformance level.
- The must-have / nice-to-have framing blends the *normative tier* (primary-sourced) with
  *use-case judgment* (analytical).

### Key sources

- [UTS #18 — Unicode Regular Expressions](https://www.unicode.org/reports/tr18/)
- [UAX #29 — Text Segmentation (grapheme clusters)](https://www.unicode.org/reports/tr29/)
- [UTS #46 — IDNA Compatibility Processing](https://unicode.org/reports/tr46/)
- [UTS #39 — Unicode Security Mechanisms (confusables)](https://www.unicode.org/reports/tr39/)
- [UTR #36 — Unicode Security Considerations](http://www.unicode.org/reports/tr36/tr36-10.html)
- [PCRE2 pattern docs](https://pcre2project.github.io/pcre2/doc/pcre2pattern/)
- [Rust regex UNICODE.md](https://github.com/rust-lang/regex/blob/master/UNICODE.md)
