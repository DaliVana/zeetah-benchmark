# zeetah in rebar

Runs zeetah's runtime meta-engine (`zeetah.Regex`) inside
[rebar](https://github.com/BurntSushi/rebar), BurntSushi's regex barometer, so it
can be ranked against rebar's curated suite and engine field.

- `main.zig` — the rebar runner: KLV on stdin, `duration_ns,count` per sample
  on stdout (same contract as rebar's Rust runners). Models: `compile`, `count`,
  `count-spans`, `count-captures`, `grep`, `grep-captures`.
- `build.sh` — builds the runner against `$ZEETAH_SRC` (the engine's
  `src/root.zig`; default `~/Develop/Zig/regex/zeetah/src/root.zig`). The
  reported version includes the engine's git rev.
- `enroll_zeetah.py` — adds `zeetah` to every curated benchmark it can
  legitimately run (see "Scope").
- `rebar_h2h.py` — head-to-head (geomean speed ratio + wins) of zeetah vs every
  other engine, from a `rebar measure` CSV.

## Scope

zeetah is byte-oriented (`CompileFlags.unicode` is not implemented) and exposes
no multi-pattern API, so the runner **refuses** `unicode = true` and
multi-pattern benchmarks rather than running them with different semantics.
That leaves 36 of the 52 curated benchmarks — all of which pass with the
engine's runtime size ceilings (heap-backed NFA up to 32 767 states, 255
capture groups, `{m,n}` ≤ 65 535; see `docs/ARCHITECTURE.md` in the engine). Captures reuse one scratch buffer
per match (reset after each match), the analogue of PCRE2's reused match data.

## Reproduce

```sh
git clone https://github.com/BurntSushi/rebar && cd rebar
mkdir -p engines/zeetah && cp /path/to/zeetah-benchmark/rebar/{main.zig,build.sh} engines/zeetah/
cat >> benchmarks/engines.toml <<'TOML'

[[engine]]
  name = "zeetah"
  cwd = "../engines/zeetah"
  [engine.version]
    bin = "./zig-out/main"
    args = ["--version"]
  [engine.run]
    bin = "./zig-out/main"
  [[engine.dependency]]
    bin = "zig"
    args = ["version"]
    regex = '^0\.16\.'
  [[engine.build]]
    bin = "./build.sh"
  [[engine.clean]]
    bin = "rm"
    args = ["-rf", "./zig-out", "./.zig-cache"]
TOML
python3 /path/to/zeetah-benchmark/rebar/enroll_zeetah.py .
cargo build --release
./target/release/rebar build -e '^(zeetah|rust/regex|dotnet/compiled|dotnet/nobacktrack)$'
./target/release/rebar measure -f '^curated/' -e '^(zeetah|rust/regex|...)$' > results.csv
./target/release/rebar rank results.csv -M compile
python3 /path/to/zeetah-benchmark/rebar/rebar_h2h.py results.csv
```

### macOS arm64 build notes (rebar @ 463d00f)

Rebar is only tested on Linux; three engines need local fixes on Apple Silicon:

- **pcre2** — `engines/pcre2/build.rs`: skip `pcre2posix.c` (its header is not
  vendored), fix the sljit include path to `upstream.join("deps/sljit/sljit_src")`,
  and drop the `aarch64-apple` exclusion in `enable_jit` (otherwise `pcre2/jit`
  reports "JIT is not enabled"; sljit works fine there).
- **re2** — build with Abseil's headers visible:
  `PKG_CONFIG_PATH=$(brew --prefix abseil)/lib/pkgconfig CXXFLAGS=-I$(brew --prefix abseil)/include cargo build --release`
  in `engines/re2`.
- **icu** — the dependency check's regex rejects Homebrew's pkg-config flag
  order; build directly with `PKG_CONFIG_PATH=$(brew --prefix icu4c@78)/lib/pkgconfig cargo build --release`
  in `engines/icu`.
- **python** — needs `virtualenv`; instead create `engines/python/ve` with
  `python3 -m venv ve && ve/bin/pip install regex`.
