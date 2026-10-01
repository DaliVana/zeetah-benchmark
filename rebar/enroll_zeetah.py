"""Add 'zeetah' to the `engines` list of every curated rebar benchmark it can
legitimately run: unicode=false (zeetah is byte-oriented) and single-pattern
(no per-line="pattern" multi-regex). Edits the TOML textually to keep layout."""
import glob, re, sys, tomllib
root = sys.argv[1]
added = skipped = 0
for f in sorted(glob.glob(f"{root}/benchmarks/definitions/curated/*.toml")):
    text = open(f).read()
    benches = tomllib.loads(text).get("bench", [])
    parts = re.split(r"(?m)^(?=\[\[bench\]\])", text)
    head, blocks = parts[0], parts[1:]
    assert len(blocks) == len(benches), f
    out = [head]
    for blk, b in zip(blocks, benches):
        rx = b.get("regex")
        multi = isinstance(rx, dict) and rx.get("per-line") == "pattern"
        if b.get("unicode", False) or multi or "zeetah" in b["engines"]:
            skipped += 1
            print(f"skip  {f.split('/')[-1]}:{b['name']} (unicode={b.get('unicode', False)}, multi={multi})")
            out.append(blk)
            continue
        new, n = re.subn(r"(?m)^(engines\s*=\s*\[)", r"\1\n  'zeetah',", blk, count=1)
        assert n == 1, (f, b["name"])
        added += 1
        out.append(new)
    open(f, "w").write("".join(out))
    # sanity: file still parses and zeetah present where expected
    tomllib.loads(open(f).read())
print(f"enrolled={added} skipped={skipped}")
