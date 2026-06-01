#!/usr/bin/env python3
"""Deterministic synthetic log corpus for the structured-extraction workloads.

Unlike the mixed `corpus.txt` (where the log/date patterns match only the
sparse tokens that happen to land on a line), *every* line of this file is a
well-formed log record

    YYYY-MM-DD HH:MM:SS.mmm LEVEL <message>

so the `log_parse` workload — `(timestamp) (level) (message)` — and the
`date_fields` workload — `(\\d{4})-(\\d{2})-(\\d{2})` over the leading date —
hit on *every* line. That makes these the dense, per-line-allocation-bound
cases the workloads are meant to model: the search itself is trivial, and what
dominates is the per-match capture extraction (one `Captures`/ovector copy per
line) over a varied message-length distribution.

The message length is drawn from buckets spanning three orders of magnitude
(a few chars to a couple of kilobytes), so the per-line work — and the cost a
naive "allocate a buffer per line" extractor pays — varies wildly across the
file. The first lines are kept short so even the 1 KiB slice holds several
complete records.

Strictly ASCII (so `\\w` / `\\d` / `.` coincide across every engine and the
cross-engine correctness gate stays green) and seeded (no system randomness),
so re-running yields byte-identical output and therefore identical match counts
across runs, machines and engines. Whole `\\n`-terminated lines only; a size
slice may cut the final line mid-record (consistent across all engines).

Usage: gen_logs.py [out_path]   (default logs.txt)
"""
import sys

# Comfortably larger than the largest slice (1 MiB) so that slice is full and
# still ends mid-record exactly like the mixed corpus does.
TARGET_BYTES = 1 << 20 | 1 << 18  # ~1.25 MiB

LEVELS = ["TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL"]

# A pool of log-message word fragments — bare words, key=value pairs, paths,
# ids and small numbers — so messages read like real structured logs while
# staying ASCII and free of any `dddd-dd-dd` date shape (keeps date_fields at
# exactly one match per line).
FRAGMENTS = [
    "request", "completed", "in", "ms", "user", "session", "expired",
    "connection", "pool", "exhausted", "retrying", "timeout", "after",
    "cache", "miss", "for", "key", "flushing", "buffer", "to", "disk",
    "GET", "POST", "PUT", "DELETE", "status=200", "status=404", "status=500",
    "latency=12", "latency=480", "bytes=1024", "thread=worker-7",
    "path=/api/v1/orders", "host=db-primary", "shard=3", "queue=ingest",
    "rows=42", "took=0.13s", "code=ECONNRESET", "attempt=2", "of=5",
    "deserializing", "payload", "rejected", "by", "validator", "field",
    "reconnecting", "upstream", "heartbeat", "missed", "leader", "election",
    "compaction", "started", "segment", "sealed", "offset=98231", "lag=0",
]


def lcg(seed):
    """Tiny deterministic PRNG (Numerical Recipes LCG)."""
    state = seed & 0xFFFFFFFF
    while True:
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        yield state


def msg_word_count(r, line_idx):
    """Wildly varied message length. The first 24 lines are forced short so the
    smallest size slices still contain several complete records; after that the
    bucket distribution spans three orders of magnitude."""
    if line_idx < 24:
        return 2 + (r % 6)
    band = r % 1000
    if band < 420:               # tiny: 1-3 words
        return 1 + (r >> 5) % 3
    if band < 720:               # small: 4-12 words
        return 4 + (r >> 5) % 9
    if band < 920:               # medium: 20-60 words
        return 20 + (r >> 5) % 41
    if band < 980:               # large: 100-300 words
        return 100 + (r >> 5) % 201
    return 800 + (r >> 5) % 1201  # huge: 800-2000 words


def make_line(rng, line_idx):
    r = next(rng)
    year = 2020 + r % 6
    month = 1 + (r >> 3) % 12
    day = 1 + (r >> 7) % 28
    hh = (r >> 11) % 24
    mm = (r >> 16) % 60
    ss = (r >> 22) % 60
    mmm = next(rng) % 1000
    level = LEVELS[next(rng) % len(LEVELS)]
    n = msg_word_count(next(rng), line_idx)
    words = [FRAGMENTS[(next(rng) >> 3) % len(FRAGMENTS)] for _ in range(n)]
    msg = " ".join(words)
    return (f"{year:04d}-{month:02d}-{day:02d} "
            f"{hh:02d}:{mm:02d}:{ss:02d}.{mmm:03d} {level} {msg}")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "logs.txt"
    rng = lcg(0x10901E)
    buf = []
    size = 0
    line_idx = 0
    while size < TARGET_BYTES:
        line = make_line(rng, line_idx)
        buf.append(line)
        size += len(line) + 1
        line_idx += 1
    data = ("\n".join(buf) + "\n").encode("ascii")
    with open(out, "wb") as f:
        f.write(data)
    sys.stderr.write(f"wrote {len(data)} bytes ({line_idx} log lines) to {out}\n")


if __name__ == "__main__":
    main()
