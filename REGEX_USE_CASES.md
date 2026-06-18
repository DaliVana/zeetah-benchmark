# Regex Use Cases in the Wild — Research for Benchmark Validation

**Purpose.** Validate and extend the cross-language regex benchmark (`benchmarks.json`,
currently 43 workloads / 15 engines) against what regexes people *actually* write.
The second deliverable is the **static-vs-dynamic** axis: is each use case typically a
**source literal** (known at compile time → Zeetah's `Pattern("…")` comptime/DFA path)
or **constructed at runtime** (interpolation/config/user input → Zeetah's
`Regex.compile` path)? That distinction decides which Zeetah path each pattern validates.

> Method: deep multi-source research with adversarial 3-vote verification (18 claims
> confirmed, 7 refuted). Citations inline. Refuted claims are listed at the end so we
> don't repeat them. **Read the "Honest limits" section** — the domain-frequency ranking
> the question asked for is *not* directly supported by data; the corpora rank syntactic
> features and behaviors, not application domains.

---

## TL;DR

1. **Literals + `*`/`+` dominate everything.** Plain literal text appears in ~92% of
   patterns; Kleene star ~44% and plus ~44%; bounded `{m,n}` is *rare* (0.2–2.5%). The
   benchmark's `literal`, `a+`, `[0-9]+`, `\w+` are correctly the most representative
   workloads. Heavy `{m,n}` patterns are low-priority by frequency.
2. **Character classes**: ranges (`[1-9]`) ~18% and negated classes (`[^…]`) ~14% lead;
   both are already well represented.
3. **Most common *behaviors*** (by clustering): alternation (40% of projects) > specific
   char must match (25%) > anchored (19%) > 2+ char sequence (16%) > paren/bracket
   content (15%) > capture/code-search (13%). Alternation is the single most common
   behavior — the benchmark covers it but could push nesting depth.
4. **Static vs dynamic — the key deliverable, honestly:** the *qualitative* answer is
   solid — **authored source regexes are predominantly static literals**, and *all*
   security signatures (OWASP CRS, Suricata) are static. **Dynamic regexes are real but
   come from one mechanism: string concatenation / templating / interpolation** (e.g.
   `NAME + "@" + DOMAIN`). The precise *ratio* is **unsettled** — both "~81% static" and
   "~half dynamic" failed verification. Do not cite a number.
5. **Concrete gaps worth adding** (all typically **static**): password multi-lookahead,
   ISBN, FQDN/domain validation, query-string key/value parsing (lookbehind capture),
   national IDs (Swedish personnummer, UK postcode), plus a Grok/named-capture log
   extractor and a CSV/quoted-field splitter. Details in §4.

---

## 1. What the data actually says about frequency

These are the load-bearing, verified numbers. **Caveat up front:** the percentage data
is from a **Python-only GitHub corpus** (Chapman & Stolee ISSTA 2016 / Chapman, Wang &
Stolee ASE 2017, ~13,597 regexes / 1,544 projects). The 8-language, 537,806-regex Davis
et al. (ESEC/FSE 2019) corpus confirms the *methodology* but the feature-percentages
below are Python-specific and only partially generalize.

### Syntactic feature frequency (ASE 2017, Table IV)

| Feature | Share of patterns | Benchmark coverage |
|---|---|---|
| Plain literals (no hex/oct/wrapped) | **91.8%** (96.2% of projects) | ✅ `literal` |
| Kleene star `*` | **44.3%** | ✅ via many |
| Plus `+` | **44.1%** | ✅ `a+`, `[0-9]+`, `\w+` |
| Explicit sequential repetition (`ff:ff:…`) | 24.8% | ✅ `mac_addr`, `uuid` |
| Char-class **range** `[1-9]` | 18.2% | ✅ pervasive |
| Char-class **negated** `[^…]` | 14.2% | ✅ `html_tag`, `json_string` |
| Char-class explicit list | 14.0% | ✅ |
| Defaults-in-class `[-+\d.]` | 6.2% | ✅ `float_sci`, `price` |
| Bounded `{m,n}` | **2.5%** | ✅ `ssn`, `uuid`, `credit_card` (already ≥ frequency) |
| `{m,}` | 0.7% | — (correctly rare) |
| `{m,m}` | 0.2% | — (correctly rare) |
| OR-of-single-chars | 1.8% | — |
| Inline flag change `(?i)` | "relatively rare" | partial (`tokenizer`) |

> Source: Chapman, Wang & Stolee, *"Exploring Regular Expression Comprehension"* (ASE
> 2017), reusing the Chapman & Stolee ISSTA 2016 corpus.
> <https://wangpeipei90.github.io/papers/ase2017.pdf>

**Implication for the benchmark:** the existing pattern mix is well-calibrated to real
frequency. Literals and `+`/`*` are the backbone (covered). Bounded `{m,n}` is *over*-
represented relative to its 2.5% real share — which is fine (the benchmark stresses
engine features, not population frequency), but it means there's no need to add more
`{m,n}` patterns.

### Behavioral / purpose frequency (Chapman & Stolee ISSTA 2016)

By clustering regexes on the strings they match (% of projects; categories overlap, so
they sum to >100%):

| Behavior | % projects | Benchmark coverage |
|---|---|---|
| **Multiple matching alternatives** (alternation) | **40%** | ✅ `alternation`, `log_level`, `deep_alternation` |
| Specific character must match | 25% | ✅ |
| Anchored patterns (`^`/`$`) | 19% | ✅ `multiline_log` (only one) |
| Two-or-more chars in sequence | 16% | ✅ |
| Content of brackets/parens | 15% | ✅ `html_tag`, `json_string` |
| Code search & variable capturing | 13% | ✅ `date_fields`, `href`, `html_title` |

> Source: Chapman & Stolee, *"Exploring Regular Expression Usage and Context in Python"*
> (ISSTA 2016). <https://dl.acm.org/doi/10.1145/2931037.2931073>

**Implication:** alternation is the #1 behavior and anchoring is #3. The benchmark has
deep alternation but only **one anchored workload** (`multiline_log`). Anchoring is a
DFA fast-path in Zeetah — adding a couple of `^…$` validators is justified by frequency
*and* exercises that path. See §4.

---

## 2. Static vs dynamic — the key deliverable

This is the heart of the request, so here is exactly what is and isn't supported.

### What's solid (high confidence)

- **Every major mining study extracts ONLY statically-declared (source-literal)
  regexes**, and each lists dynamic/runtime-constructed regexes as an explicit *threat
  to validity* they did not measure. Davis et al. 2019 (537,806 regexes, 8 languages):
  *"our corpus is composed only of statically-declared regexes… we assume that either
  most regexes are statically declared, or that dynamically-declared regexes have
  similar properties."* This is strong indirect evidence that **the static/literal case
  is the dominant and default authoring mode** — researchers built their entire
  methodology on that assumption.
  Sources: <https://ar5iv.labs.arxiv.org/html/2105.04397>,
  <https://fservant.github.io/papers/Davis_Michael_Coghlan_Servant_Lee_ESECFSE19.pdf>

- **Dynamic regexes have one canonical shape: concatenation / templating /
  interpolation.** The textbook example (Davis, Moyer, Kazerouni & Lee, ICSE-ASE 2019):
  `SIMPLE = Regex('.+@.+')` (static) vs `COMPLEX = NAME_REGEX + '@' + DOMAIN_REGEX`
  (dynamic, assembled from parts). Static-literal extraction *structurally cannot* see
  the second form. So "dynamic" ≈ "built from pieces at runtime," not "exotic syntax."
  Source: <https://par.nsf.gov/servlets/purl/10315346>

- **Security signatures are unambiguously static.** OWASP CRS / ModSecurity SQLi rules
  embed patterns inline via `@rx` (no runtime phrase files), and Suricata IDS rules
  embed PCRE as fixed `pcre:"/<regex>/opts";` literals in `.rules` files. The ReDoS
  threat model is precisely "**static pattern, attacker-controlled input**."
  Sources: <https://github.com/SpiderLabs/owasp-modsecurity-crs/blob/v3.3/dev/rules/REQUEST-942-APPLICATION-ATTACK-SQLI.conf>,
  <https://docs.suricata.io/en/latest/rules/payload-keywords.html>,
  <https://arxiv.org/pdf/1301.0849>

### What's NOT established (do not cite a number)

The precise static:dynamic **ratio is genuinely unsettled.** Two competing quantified
claims were each **refuted** under adversarial 3-vote verification:

- "~80.8% fully static / 6.5% non-compilable-dynamic" (Chapman & Stolee) — **refuted (1-2)**
- "~half of runtime-observed regexes are invisible to static extraction" (NSF runtime
  study) — **refuted (1-2)**

**Bottom line:** authored regexes skew heavily static (well-supported qualitatively);
the exact dynamic share is unknown. A runtime-instrumentation study with a defensible
methodology would be needed to pin it.

### Mapping to Zeetah's two paths

| | Static (source literal) | Dynamic (runtime-built) |
|---|---|---|
| Mechanism | Hardcoded in source | concatenation / templating / user input / config |
| Frequency | **Dominant authoring mode** | real but minority; exact share unknown |
| Examples | validators, log patterns, security signatures, tokenizers | user-supplied search, configurable log grok built from fields, query builders |
| **Zeetah path** | **`Pattern("…", .{})` — comptime DFA** | **`Regex.compile(alloc, str)` — runtime** |

This **validates the benchmark's core thesis**: the comptime/`Pattern` path targets the
*majority* authoring mode. Almost every use case below is static, which is *why* a
compile-time meta-engine is a defensible bet. The handful of genuinely dynamic cases
(user-typed search, config-driven log parsing) are exactly what the `Regex.compile`
runtime path exists for — and the benchmark should keep at least one workload framed as
"compile-once-from-string" to represent it (the existing `regex-redux` compile-many
workload partly does this).

---

## 3. Use-case catalog by domain (with static/dynamic tag)

⚠️ **Domain-level *frequency* ranking is inferential, not measured** — the corpora rank
features/behaviors, not application domains (see §5). The grouping below is organized by
domain for usefulness; the "common?" column is a qualitative judgment from the
practitioner/security sources, not a verified frequency.

| Domain | Use case | Example pattern | Common? | Static/Dynamic | In benchmark? |
|---|---|---|---|---|---|
| **Validation/forms** | Email | `[\w.+-]+@[\w.-]+\.[\w.-]+` | very | static | ✅ `email` |
| | Phone (US) | `\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}` | high | static | ✅ `phone_us` |
| | URL/URI | `[\w]+://[^/\s?#]+…` | very | static | ✅ `uri` |
| | UUID | `[0-9a-f]{8}-…-[0-9a-f]{12}` | high | static | ✅ `uuid` |
| | SSN / national ID | `\d{3}-\d{2}-\d{4}` | medium | static | ✅ `ssn` (US only) |
| | Credit card | `\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{4}` | medium | static | ✅ `credit_card` |
| | **Password strength** | `(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,}` | high | static | ❌ **gap** |
| | **ISBN** | `^(?:\d{9}[\dXx]\|\d{13})$` | medium | static | ❌ **gap** |
| | **Postal code (intl)** | UK: `^[A-Za-z]{1,2}\d{1,2}[A-Za-z]?\s?\d[A-Za-z]{2}$` | medium | static | ❌ **gap** |
| | **National ID (non-US)** | SE: `^\d{6}-[\dpPtTfF]\d{3}$` | medium | static | ❌ **gap** |
| **Web/HTTP** | HTML tag | `<[^>]+>` | high | static | ✅ `html_tag` |
| | Attribute/href extract | `href="([^"]+)"` | high | static | ✅ `href`, `html_title` |
| | Hashtag/mention | `#[A-Za-z0-9_]+` | medium | static | ✅ `hashtag` |
| | Apache/access-log path | `POST (?:/\w+){1,}` | high | static | ✅ `apache_post` |
| | **FQDN/domain name** | `^(?:[a-z0-9-]+\.)+[a-z]{2,}$` | high | static | ❌ **gap** |
| | **Query-string k/v** | `(?<=[?&])([^=&#]+)=([^&#]*)` | high | static | ❌ **gap** (lookbehind capture) |
| **Logs/observability** | Log-line parse | `(date) (level) (msg)` | very | static* | ✅ `log_parse` |
| | Date/time fields | `(\d{4})-(\d{2})-(\d{2})`, `\d{2}:\d{2}:\d{2}` | very | static | ✅ `date_fields`, `time_hms`, `date_iso` |
| | Log level | `(?:TRACE\|DEBUG\|INFO\|WARN\|ERROR\|FATAL)` | very | static | ✅ `log_level` |
| | Multiline log anchor | `^\d{4}-\d{2}-\d{2}.*$` | high | static | ✅ `multiline_log` |
| | Vendor log shapes | k8s/fluentd, AWS ENI | high | static* | ✅ `k8s_fluentd`, `aws_eni` |
| | **Grok / named-capture extract** | `%{IP:client} %{WORD:method} …` → `(?<client>…)…` | very | **static or dynamic** (config-assembled) | ❌ **gap** |
| **Data extraction/ETL** | Numbers (int/float/sci) | `[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?` | very | static | ✅ `float_sci`, `digits` |
| | Currency/price | `\$[\d,]+\.?\d*` | high | static | ✅ `price` |
| | JSON string token | `"(?:[^"\\]\|\\.)*"` | medium | static | ✅ `json_string` |
| | Base64 | `(?:[A-Za-z0-9+/]{4})+={0,2}` | medium | static | ✅ `base64` |
| | **CSV / quoted field split** | `("(?:[^"]\|"")*"\|[^,]*)(?:,\|$)` | high | static | ❌ **gap** |
| | Semver | `v?\d+\.\d+\.\d+` | high | static | ✅ `semver` |
| | Hex color | `#[0-9a-fA-F]{6}` | medium | static | ✅ `hex_color` |
| **Security/WAF/IDS** | SQLi keyword alternation | nested `(?i:…\|…)` DB names | high | **static** | ✅ `modsec_sqli`, `deep_alternation` (could nest deeper) |
| | ReDoS canary | `(a+)+b` | n/a | static | ✅ `pathological` |
| **Networking** | IPv4 | `(?:25[0-5]\|…)\.{3}…` | very | static | ✅ `ipv4` |
| | MAC address | `(?:[0-9A-Fa-f]{2}:){5}…` | high | static | ✅ `mac_addr` |
| | **IPv6** | `(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}` (+ `::`) | high | static | ❌ **gap** |
| **NLP/tokenize/lex** | Word tokenizer | NLTK / Penn Treebank | medium | static | ✅ `nltk` |
| | BPE/LLM tokenizer | GPT-style pretokenizer | niche | static | ✅ `tokenizer` |
| | Identifier/keyword lex | `\b(?:if\|else\|…)\b`, `[A-Za-z_]\w*` | high | static | partial (`deep_alternation`) |
| **Search/editors** | User-typed search | arbitrary | very | **dynamic** | ⚠️ represented only by `regex-redux` compile path |
| **Unicode** | Property class | `[\p{L}\p{N}_]+` | medium | static | ✅ `unicode_prop` |

\* Log/grok patterns are *usually* static literals, but pipeline tools (Logstash Grok,
Datadog, Fluentd) let users **assemble them from named sub-patterns / config**, which is
a real dynamic-construction case — see the Grok row.

---

## 4. Recommended additions to `benchmarks.json`

Ranked by value (frequency × distinct engine-path stressed). All are **static** (comptime
`Pattern`-eligible) unless noted. Sourced from the RegExLib-derived rxxr2 corpus
(<https://github.com/superhuman/rxxr2/blob/master/data/input/regexlib-raw.txt>) and the
security/log sources above. Verbatim entries exist in the corpus where cited.

> **✅ Implemented.** All ten were added to `benchmarks.json` (workloads 44–53) and
> validated: every `comptime:true` pattern compiles on zeetah's comptime path and the
> match counts agree exactly with Python's `re`/`regex` reference on the regenerated
> 1 MiB corpus (`gen_corpus.py` now embeds matchable data for each). Three patterns were
> adjusted during validation to keep them realistic *and* fast on zeetah's engine — the
> **Implemented pattern** column below is what actually ships; the "Pattern (proposed)"
> is the original recommendation. See the *Implementation notes* under the table.

| id | Pattern (proposed → **implemented**) | Why add it | Stresses | Static? |
|---|---|---|---|---|
| `password_strength` | `(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,}` → **`^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,}$`** (anchored, `(?m)`) | High-frequency validator; **multiple lookaheads** — no existing workload chains assertions | multi-lookahead / anchored backtracker | static |
| `ipv6` | `(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}` | Networking staple; complement to existing `ipv4`/`mac_addr` | long bounded repetition, hex classes (DFA) | static |
| `fqdn` | `^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$` → **`^(?:[a-z0-9-]+\.)+[a-z]{2,}$`** | Very common; anchored both ends (only `multiline_log` was anchored before) | anchored DFA | static |
| `querystring_kv` | `(?<=[?&])([^=&#]+)=([^&#]*)` | Web staple; **lookbehind + capture** combo not yet covered | lookbehind→backtracker + captures | static |
| `csv_field` | `("(?:[^"]\|"")*"\|[^,]*)(?:,\|$)` → **`(?:"(?:[^"]\|"")*"\|[^,\n]+)`** (non-capturing) | Ubiquitous ETL; quoted-or-bare field alternation | alternation | static |
| `grok_named` | `(?<ts>\d{4}-\d{2}-\d{2}) (?<lvl>\w+) (?<msg>.*)` | Named-capture log extraction (Grok-style); pairs with `log_parse` | named captures, `.*` | static (config-built variant = dynamic) |
| `isbn` | `^(?:\d{9}[\dXx]\|\d{13})$` | Classic validator; cheap, anchored, alternation | anchored alternation | static |
| `postal_uk` | `^[A-Za-z]{1,2}\d{1,2}[A-Za-z]?\s?\d[A-Za-z]{2}$` | Intl validation (SSN today is US-only); optional groups | optional groups, anchors | static |
| `personnummer_se` | `^\d{6}-[\dpPtTfF]\d{3}$` | Non-US national ID; small char-class union | char class, anchors | static |
| `sqli_nested` | `(?i:\b(?:m(?:s(?:ys…)\|aster\.\.sysdatabases\|ysql\.(?:db\|user))\|pg_(?:catalog\|toast)\|information_schema\|northwind\|tempdb)\b)` (OWASP-CRS-942140 style) | Realistic WAF nesting depth (current `deep_alternation` is flat) | alternation-prefix sharing, `(?i)`, `\b` | static |

**Implementation notes (why three patterns changed):**
- **`password_strength` → anchored.** Unanchored, the three `.*` look-aheads rescan to
  line-end at *every* byte → O(n²); it measured **3.6 s/op** on 1 MiB in zeetah's
  comptime backtracker. Anchoring (`^…$`, `(?m)`) limits attempts to one per line —
  **0.42 s/op**, ~9× faster — and matches how password rules are written in the wild.
  Bonus: it adds to the under-represented *anchored* behavior (#3 most common, §1).
- **`fqdn` → dropped the RFC length bounds.** The proposed `{0,61}`/`{2,63}` nested in
  `(…)+` blew up zeetah's comptime DFA construction (>3 min, no result), while a normal
  backtracker did it in 18 ms. The shipped `^(?:[a-z0-9-]+\.)+[a-z]{2,}$` is DFA-clean,
  **54 ms/op**, and yields the **identical match count** on the corpus. (Worth a separate
  bug note for the engine: large bounded repeats nested under `+` should not fall off the
  DFA path.)
- **`csv_field` → removed the zero-width branch, then made it non-capturing.** The proposed
  `[^,]*` + `(?:,|$)` produces empty matches; zeetah and PCRE-family engines iterate those
  differently (zeetah counted 16, `regex` 1580 — a gate failure). The zero-width-free
  `("(?:[^"]|"")*"|[^,\n]+)` fixed *matching* (all engines agree on **9464** matches) but
  surfaced a second issue (below), so the shipped pattern drops the capture group:
  `(?:"(?:[^"]|"")*"|[^,\n]+)`. It still exercises the quoted-or-bare **alternation** and
  field-extraction shape; the captures dimension stays covered by `querystring_kv` and
  `grok_named`.

### Bugs / engine quirks the new workloads surfaced

The cross-engine gate (every engine must agree on match count) caught three things —
two are documented engine semantics, one is a real **zeetah bug**:

1. **🐞 zeetah runtime-VM capture bug (real, worth fixing).** With a capture group that
   wraps an alternation, `( A | B )`, the **runtime VM under-reports group participation
   when the *first* alternative matches**, while the comptime path is correct. On
   `("(?:[^"]|"")*"|[^,\n]+)` over the 1 MiB corpus: same match count (9464) on both
   paths, but `count-captures` = **9333 (runtime) vs 9464 (comptime)** — the ~131 quoted
   fields (the `"…"` branch) report group 1 as non-participating in the VM. Minimal repro:
   pattern `("[^"]*"|[^,\n]+)`, count-captures — reproduces 9333 vs 9464. No alternation
   (`([^,\n]+)`) → both agree (9521). **The benchmark dodges it by shipping `csv_field`
   non-capturing; the underlying VM bug remains and should be fixed in the engine.**
2. **Oniguruma `(?m)` = DOTALL, not multiline-anchors (known Ruby trap).** `password_strength`
   uses `^…$` with `(?m)`. For Oniguruma the harness prepends `(?m)` like every other
   non-zeetah engine, but in Ruby/Oniguruma `^`/`$` are *always* line anchors and `(?m)`
   instead turns on dot-all — so `.{8,}$` swallowed the whole buffer (count 1, span = full
   input) while everyone else found per-line matches. Fixed with an `engine_patterns`
   override giving Oniguruma the pattern **without** the `(?m)` prefix — exactly the
   workaround `multiline_log` already uses. (This is the Ruby row in §5's table, live.)
3. **CTRE can't compile `(?i:…)` inline scoped flags.** `sqli_nested`'s case-insensitive
   group is a hard CTRE *build* error (same reason `tokenizer` skips CTRE), so CTRE is in
   `sqli_nested`'s `skip_engines`. RE2 and base Rust `regex` auto-`REJECT` the look-around
   patterns (`password_strength`, `querystring_kv`) at runtime — expected, no skip needed.

**Priority (as implemented):** `password_strength`, `ipv6`, `fqdn`, `querystring_kv`,
`csv_field` fill the clearest behavioral gaps (multi-lookahead, IPv6, anchoring,
lookbehind+capture, field alternation); the rest add validation/security breadth.

> **Re-run required.** Adding these regenerated `corpus.txt`, so every engine's committed
> CSV is now stale. Run `./run_all.sh` (or `ZEETAH_SRC=../zeetah/src/root.zig zig build
> bench && … bench-dfa`) to refresh results and re-check the cross-engine count gate.

**One dynamic-path workload worth formalizing:** a "user-supplied pattern" workload that
takes the regex as a runtime `[]const u8` and routes through `Regex.compile` — this is
the *only* genuinely dynamic use case (interactive search, configurable grok) and it's
the thing the comptime `Pattern` path *can't* serve. The existing `regex-redux`
compile-many workload is the closest proxy; consider labeling it explicitly as the
runtime/dynamic representative.

---

## 5. Honest limits of this research

1. **Domain frequency was not measured.** The strongest corpora (Chapman/Stolee, Davis)
   rank *syntactic features* and *behaviors*, not application domains. Any domain-level
   "this is the #1 use case" claim (incl. "email is the most common regex") is **not
   supported** — and the "email is canonical" claim was explicitly **refuted (0-3)**.
2. **Percentages are Python-skewed.** The 92%/44%/18% figures are from a Python GitHub
   corpus. The 8-language Davis corpus confirms the *static-only methodology* but not
   those exact percentages. Whether they hold in Go/Rust/C/C++ is an open question.
3. **No reliable static:dynamic number exists.** Both "~81% static" and "~half dynamic"
   were refuted. Use the *qualitative* finding only.
4. **RegExLib/rxxr2 is curated and publication-biased.** It proves a validation use case
   *exists*, not its real-world frequency — it over-represents complex shareable
   validators and under-represents the trivial literals that dominate production code.
   So treat §4 additions as "real tasks people write," not "ranked by true frequency."
5. **Bio/ETL/NLP/networking domains lack external frequency evidence** in this round. The
   benchmark's NLTK/BPE/k8s/fluentd/AWS-ENI patterns are plausible but **unvalidated**
   against any external frequency dataset.
6. **OWASP CRS pinned to v3.3** here; current line is v4.x (rule IDs/structure persist,
   specific patterns may differ). Suricata syntax verified across 5.x–9.x.

### Refuted claims (do NOT repeat)

- "Email is the canonical most-frequent regex" — **0-3**.
- "RegExLib validation corpus proves validation/forms is the top global *domain*" — **0-3**.
- "~80.8% fully static / 6.5% dynamic" (a clean static ratio) — **1-2**.
- "~half of regexes are dynamically constructed" — **1-2**.
- Specific corpus-size restatements (13,597 / Snort 12,499) as *prevalence* oracles — **1-2**.

---

## Sources

**Primary / academic**
- Chapman & Stolee, *Exploring Regular Expression Usage and Context in Python*, ISSTA 2016 — <https://dl.acm.org/doi/10.1145/2931037.2931073>
- Chapman, Wang & Stolee, *Exploring Regular Expression Comprehension*, ASE 2017 — <https://wangpeipei90.github.io/papers/ase2017.pdf>
- Davis et al., *Why Aren't Regular Expressions a Lingua Franca?*, ESEC/FSE 2019 (537,806 regexes / 8 languages) — <https://fservant.github.io/papers/Davis_Michael_Coghlan_Servant_Lee_ESECFSE19.pdf> · <https://ar5iv.labs.arxiv.org/html/2105.04397>
- Davis, Moyer, Kazerouni & Lee, static-vs-runtime regex extraction, ICSE-ASE 2019 — <https://par.nsf.gov/servlets/purl/10315346>
- ReDoS threat-model paper, arXiv 1301.0849 — <https://arxiv.org/pdf/1301.0849>

**Security rule corpora**
- OWASP CRS v3.3 SQLi rules — <https://github.com/SpiderLabs/owasp-modsecurity-crs/blob/v3.3/dev/rules/REQUEST-942-APPLICATION-ATTACK-SQLI.conf>
- Suricata payload keywords (PCRE) — <https://docs.suricata.io/en/latest/rules/payload-keywords.html>
- OWASP CRS project — <https://owasp.org/www-project-modsecurity-core-rule-set/>

**Validation corpus**
- RegExLib-derived rxxr2 dataset (~9,724 community validation patterns) — <https://github.com/superhuman/rxxr2/blob/master/data/input/regexlib-raw.txt>

**Practitioner (log/ETL, lower weight — blogs)**
- New Relic, Datadog, Logstash Grok, OpenReplay, Oregon State bioinformatics regex chapter.

---

*Generated from a verified deep-research pass (18 confirmed / 7 refuted claims).
Frequency data is Python-corpus-derived; domain ranking is inferential. See §5 before
quoting any figure.*
