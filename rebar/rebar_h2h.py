"""Head-to-head zeetah vs each engine from a rebar measurement CSV (median time).
>1 means zeetah faster. Separate search (non-compile) and compile models."""
import csv, math, re, sys, collections
U = {"ns":1e-9,"us":1e-6,"µs":1e-6,"ms":1e-3,"s":1.0}
def dur(s):
    m = re.fullmatch(r"([0-9.]+)(ns|us|µs|ms|s)", s); return float(m[1])*U[m[2]]
def load(p):
    t = collections.defaultdict(dict)
    for r in csv.DictReader(open(p)):
        if r["err"]: continue
        t[(r["name"], r["model"])][r["engine"]] = dur(r["median"])
    return t
def h2h(t, z, compile_model):
    engines = sorted({e for v in t.values() for e in v} - {z, "zeetah", "zeetah/ceiling"})
    out = []
    for e in engines:
        rs = [v[e]/v[z] for (n,m),v in t.items() if (m=="compile")==compile_model and z in v and e in v]
        if rs:
            g = math.exp(sum(map(math.log, rs))/len(rs))
            out.append((g, e, sum(r>1.0 for r in rs), len(rs)))
    return sorted(out, reverse=True)
t = load(sys.argv[1]); z = sys.argv[2] if len(sys.argv) > 2 else "zeetah"
for label, cm in (("SEARCH", False), ("COMPILE", True)):
    print(f"--- {label}: {z} vs engine (geomean speed ratio, >1 = {z} faster)")
    for g, e, w, n in h2h(t, z, cm):
        print(f"  {e:20s} {g:7.2f}x   {z} faster on {w}/{n}")
