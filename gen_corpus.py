#!/usr/bin/env python3
"""Deterministic corpus generator for the cross-engine regex benchmark.

Produces a fixed ~1 MiB text file so every engine sees byte-identical input.
The content is seeded (no system randomness), so re-running yields the same
bytes and therefore the same match counts across runs and machines.

The corpus deliberately contains, at controlled frequencies, tokens that the
benchmark patterns match. It stays strictly ASCII so `\\w` / `\\d` / `\\s` /
`\\p{L}` coincide across every engine (that is what keeps the cross-engine
correctness gate green).

Token families embedded:
  - originals: "Sherlock", 'a' runs, digit groups, words, the animal
    alternation set, email/URI/IPv4, HTML title, href, price, nltk abbrev,
    SSN, SQLi-special runs, AWS ENI, Apache POST, k8s/Fluentd log lines;
  - typical additions: ISO date, 24h time, US phone, hex colour, UUID,
    MAC address, semver, credit-card group, log level, generic HTML tag,
    hashtag;
  - edge additions: scientific float, JSON string (with `\\` escapes),
    base64 blob, unix path, programming keyword (deep alternation),
    foo/bar/baz wildcard line, and a duplicated word (backreference).

`lookbehind_amount` reuses the `$NN.NN` price-like tokens, `unicode_prop`
matches any word/digit run, and `atomic_token` reuses the `ident@` shape
from e-mail tokens — so those three need no dedicated emitter.
"""
import sys

TARGET_BYTES = 1 << 20  # 1 MiB

WORDS = [
    "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
    "regex", "engine", "thompson", "automaton", "state", "match",
    "input", "pattern", "linear", "time", "deterministic", "finite",
]
ANIMALS = ["cat", "dog", "bird", "fish"]
LEVELS = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL"]
KEYWORDS = [
    "break", "case", "catch", "class", "const", "continue", "default",
    "delete", "do", "else", "enum", "export", "extends", "false", "finally",
    "for", "function", "if", "import", "in", "instanceof", "new", "null",
    "return", "super", "switch", "this", "throw", "true", "try", "typeof",
    "var", "void", "while", "with", "yield", "async", "await", "let",
]
TAGS = ["div", "span", "p", "a", "li", "section"]
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def lcg(seed):
    """Tiny deterministic PRNG (Numerical Recipes LCG)."""
    state = seed & 0xFFFFFFFF
    while True:
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        yield state


def make_token(r):
    """Map a PRNG draw to one corpus token. Bands are cumulative over r%200,
    so existing token families keep their relative proportions while the new
    ones occupy the upper half of the range."""
    sel = r % 200
    w = WORDS[(r >> 7) % len(WORDS)]
    w2 = WORDS[(r >> 11) % len(WORDS)]
    # --- original families (unchanged shapes) ---
    if sel < 28:
        return WORDS[(r >> 7) % len(WORDS)]
    if sel < 33:
        s = ("http", "https", "ftp")[r % 3]
        return f"{s}://{w}.example.com/{w2}?id={r % 999}#sec{r % 9}"      # uri
    if sel < 45:
        return str(r % 100000)                                           # digits
    if sel < 55:
        return ANIMALS[(r >> 5) % len(ANIMALS)]                           # alternation
    if sel < 61:
        return "a" * (1 + (r % 12))                                      # a+ runs
    if sel < 67:
        return f"{w}.{(r % 999)}@{w2}-mail.example.com"                   # email
    if sel < 72:
        return "%d.%d.%d.%d" % (
            r % 256, (r >> 3) % 256, (r >> 6) % 256, (r >> 9) % 256)      # ipv4
    if sel < 75:
        return f'<h2 class="product-title">{w}</h2>'                      # html_title
    if sel < 78:
        return f'href="https://{w}.example.com/{w2}"'                     # href
    if sel < 81:
        return f"${r % 9999},{(r >> 5) % 999}.{r % 100:02d}"             # price
    if sel < 84:
        return f"{chr(65 + (r % 26))}.{chr(65 + ((r >> 5) % 26))}."       # nltk abbrev
    if sel < 87:
        return "%03d-%02d-%04d" % (
            r % 1000, (r >> 4) % 100, (r >> 9) % 10000)                   # ssn
    if sel < 90:
        return "a'+b=c|d;e--#@$%^&*()"                                    # modsec_sqli
    if sel < 92:
        return f"eni-{r:08x}"                                             # aws_eni
    if sel < 95:
        return f"POST /{w}/{w2}"                                          # apache_post
    if sel < 98:
        lvl = ("INFO", "WARN", "ERROR")[r % 3]
        return (f"2026-05-16 12:34:56.789 {lvl} {r % 99999} "
                f"[ main ] com.example.{w} : log message {r % 999}")      # k8s_fluentd
    if sel < 100:
        return "Sherlock"                                                # literal
    # --- typical additions ---
    if sel < 105:
        return f"{2000 + r % 26}-{1 + (r >> 3) % 12:02d}-{1 + (r >> 6) % 28:02d}"  # date_iso
    if sel < 110:
        return f"{r % 24:02d}:{(r >> 3) % 60:02d}:{(r >> 6) % 60:02d}"    # time_hms
    if sel < 114:
        if r & 1:
            return f"({100 + r % 900}) {100 + (r >> 4) % 900}-{1000 + (r >> 9) % 9000}"
        return f"{100 + r % 900}-{100 + (r >> 4) % 900}-{1000 + (r >> 9) % 9000}"  # phone_us
    if sel < 118:
        return f"#{r % 0xFFFFFF:06x}"                                     # hex_color
    if sel < 122:
        return (f"{r:08x}-{(r >> 4) & 0xffff:04x}-{(r >> 8) & 0xffff:04x}-"
                f"{(r >> 12) & 0xffff:04x}-{(r * 1103515245) & 0xffffffffffff:012x}")  # uuid
    if sel < 126:
        return ":".join(f"{(r >> (i * 3)) & 0xff:02x}" for i in range(6))  # mac_addr
    if sel < 130:
        return f"v{r % 20}.{(r >> 4) % 30}.{(r >> 9) % 100}"             # semver
    if sel < 133:
        return (f"{4000 + r % 5999} {1000 + (r >> 4) % 9000} "
                f"{1000 + (r >> 9) % 9000} {1000 + (r >> 14) % 9000}")    # credit_card
    if sel < 137:
        return LEVELS[r % len(LEVELS)]                                    # log_level
    if sel < 141:
        return f'<{TAGS[r % len(TAGS)]} class="{w}">'                     # html_tag
    if sel < 145:
        return f"#{w}{r % 99}"                                            # hashtag
    # --- edge additions ---
    if sel < 150:
        if r & 1:
            return f"{r % 1000}.{(r >> 4) % 1000}e{'+' if r & 2 else '-'}{r % 30}"
        return f"{r % 10000}.{(r >> 3) % 100:02d}"                        # float_sci
    if sel < 155:
        return '"' + w + chr(92) + "t" + w2 + '"'                        # json_string (\t escape)
    if sel < 160:
        return "".join(B64[(r >> i) & 0x3F] for i in range(8)) + "=="     # base64
    if sel < 165:
        return f"/usr/{w}/{w2}.conf"                                      # path_unix
    if sel < 172:
        return KEYWORDS[r % len(KEYWORDS)]                                # deep_alternation
    if sel < 176:
        return f"foo {w} bar {w2} baz"                                    # wildcard_gaps
    if sel < 180:
        return f"{w} {w}"                                                 # backref_word (dup)
    if sel < 188:
        return f"${r % 100000}.{r % 100:02d}"                             # lookbehind_amount
    # tail: plain words keep lines natural-looking
    return WORDS[(r >> 3) % len(WORDS)]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "corpus.txt"
    rng = lcg(0xC0FFEE)
    buf = []
    size = 0
    while size < TARGET_BYTES:
        n = 6 + (next(rng) % 10)
        parts = [make_token(next(rng)) for _ in range(n)]
        line = " ".join(parts)
        buf.append(line)
        size += len(line) + 1

    data = ("\n".join(buf) + "\n").encode("ascii")[:TARGET_BYTES]
    with open(out, "wb") as f:
        f.write(data)
    sys.stderr.write(f"wrote {len(data)} bytes to {out}\n")


if __name__ == "__main__":
    main()
