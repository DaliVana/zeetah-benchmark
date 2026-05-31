#!/usr/bin/env python3
"""Canonical loader + per-engine transform for the cross-engine regex benchmark.

`benchmarks.json` is the single source of truth. This module is the ONE place
that turns it into a per-engine, per-model workload list, so every harness sees
identical patterns and model selections. The two Python harnesses import it
directly; `gen_workloads.py` imports it to emit equivalent source for the
compiled-language harnesses (Zig / Rust / C++ / C#).

Per-engine transforms applied here (and ONLY here):
  - multiline: a `multiline_log`-style pattern is stored in its base `^…$`
    form. zeetah / zeetah-dfa consume it with a `multiline` struct flag; every
    other engine gets a `(?m)` prefix instead (the inline-flag peer).
  - engine_patterns: a verbatim per-engine override (e.g. the .NET `tokenizer`
    spelled with atomic groups instead of possessive quantifiers).
  - skip_engines: engines that must emit REJECTED for the workload regardless
    of whether they would compile it (mvzr silently mis-parses several
    patterns into a different language rather than erroring).
  - dfa: only `dfa: true` workloads appear in the comptime-DFA harness.
  - captures: the count-captures model runs only on capture-bearing workloads
    AND only on engines with a participating-group API (`captures_engines`).

Models (see README.md): every corpus workload runs `count`; `spans` and `grep`
add per-match / per-line models; `captures` adds count-captures where eligible.
`regex-redux` is a separate compile-many-search-once composite.
"""
import json
import os
from dataclasses import dataclass, field
from typing import Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST_PATH = os.environ.get("BENCH_MANIFEST", os.path.join(HERE, "benchmarks.json"))

# Engines that consume the base (un-`(?m)`-prefixed) pattern because they apply
# multiline via a compile flag rather than an inline group.
_STRUCT_MULTILINE_ENGINES = ("zeetah", "zeetah-dfa")


@dataclass
class ResolvedWorkload:
    id: str
    pattern: str          # exact bytes this engine's compile() should receive
    kind: str             # "corpus" | "pathological"
    input: str            # "corpus" | "synthetic"
    multiline: bool       # engine consumes a multiline STRUCT FLAG (zeetah only)
    spans: bool           # run the count-spans model
    grep: bool            # run the grep model
    captures: bool        # run the count-captures model
    force_reject: bool    # emit REJECTED without attempting (skip_engines)


_cache: Optional[dict] = None


def manifest() -> dict:
    global _cache
    if _cache is None:
        with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
            _cache = json.load(f)
        _validate(_cache)
    return _cache


def _validate(m: dict) -> None:
    seen = set()
    for w in m["workloads"]:
        if "id" not in w or "pattern" not in w:
            raise ValueError(f"workload missing id/pattern: {w}")
        if w["id"] in seen:
            raise ValueError(f"duplicate workload id: {w['id']}")
        seen.add(w["id"])
        bad = set(w) - {
            "id", "pattern", "kind", "input", "multiline", "dfa",
            "spans", "grep", "captures", "skip_engines", "engine_patterns",
            "count_overrides",
        }
        if bad:
            raise ValueError(f"workload {w['id']} has unknown keys: {bad}")
    for e in m["captures_engines"] + m["redux_engines"]:
        if e not in m["engines"]:
            raise ValueError(f"unknown engine in capability list: {e}")


def engines() -> List[str]:
    return list(manifest()["engines"])


def sizes_for(engine: str) -> List[int]:
    m = manifest()
    if engine in _STRUCT_MULTILINE_ENGINES:
        return list(m["corpus_sizes_zeetah"])
    return list(m["corpus_sizes_std"])


def synthetic_len() -> int:
    return int(manifest()["synthetic_len"])


def redux_size() -> int:
    return int(manifest()["redux_size"])


def redux_for(engine: str) -> List[str]:
    """Ordered member patterns for the regex-redux composite, or [] if this
    engine does not run it."""
    m = manifest()
    if engine in m["redux_engines"]:
        return list(m["redux_members"])
    return []


def _resolve_pattern(w: dict, engine: str) -> str:
    overrides = w.get("engine_patterns", {})
    if engine in overrides:
        return overrides[engine]
    pat = w["pattern"]
    if w.get("multiline", False) and engine not in _STRUCT_MULTILINE_ENGINES:
        pat = "(?m)" + pat
    return pat


def workloads_for(engine: str) -> List[ResolvedWorkload]:
    """Resolved, per-engine workload list. For zeetah-dfa this is the
    `dfa: true` subset; for every other engine it is the full set (engines
    that cannot express a feature emit REJECTED at runtime via their compiler;
    `skip_engines` covers engines that mis-parse instead of erroring)."""
    m = manifest()
    cap_ok = engine in m["captures_engines"]
    out: List[ResolvedWorkload] = []
    for w in m["workloads"]:
        if engine == "zeetah-dfa" and not w.get("dfa", False):
            continue
        kind = w.get("kind", "corpus")
        corpus = kind == "corpus"
        out.append(ResolvedWorkload(
            id=w["id"],
            pattern=_resolve_pattern(w, engine),
            kind=kind,
            input=w.get("input", "corpus"),
            multiline=bool(w.get("multiline", False)) and engine in _STRUCT_MULTILINE_ENGINES,
            spans=bool(w.get("spans", corpus)),
            grep=bool(w.get("grep", corpus)),
            captures=bool(w.get("captures", False)) and cap_ok,
            force_reject=engine in w.get("skip_engines", []),
        ))
    return out


# --- source-literal escaping (used by gen_workloads.py) ---------------------

_SIMPLE = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t"}


def escape_literal(s: str) -> str:
    """Return the CONTENT of a double-quoted string literal whose runtime value
    is exactly `s`, valid simultaneously in Zig / Rust / C++ / C# normal
    (non-raw) string literals.

    The key property: EVERY backslash is doubled, so the emitted source never
    contains a `\\w` / `\\d` / `\\x` / `\\0` sequence — which would be an invalid
    escape (Rust/C#/Zig) or a greedy hex/octal escape (C++). All other bytes,
    including the UTF-8 of `´’‘`, pass through unchanged (the source file is
    UTF-8 and every target compiler reads the bytes verbatim)."""
    return "".join(_SIMPLE.get(ch, ch) for ch in s)
