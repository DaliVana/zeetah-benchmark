// Cross-engine benchmark harness — .NET System.Text.RegularExpressions side.
//
// Emits CSV rows (no header) with the schema shared by all harnesses (note the
// `model` column — see README.md):
//
//   engine,model,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
//
// The workload table is NOT declared here: it is generated from the single
// source of truth (`benchmarks.json`) into `gen/workloads_dotnet.cs` by
// `gen_workloads.py`, so patterns can never drift across the harnesses. This
// file owns only the timing methodology and the per-model measurement logic.
//
// Uses the DEFAULT .NET regex engine (backtracking). A 2 s MatchTimeout is set
// so the catastrophic-backtracking workload fails fast (note=TIMEOUT) instead
// of hanging — which is itself the headline result for that row.
//
// Corpus path: CORPUS env var, else corpus.txt
// (run_all.sh runs every harness from the repo root).

using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

internal static class Program
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(2);

    private static long NowNs() =>
        (long)(Stopwatch.GetTimestamp() * (1_000_000_000.0 / Stopwatch.Frequency));

    private static void EmitRow(
        string model, string workload, int inputBytes, int iterations,
        long compileNs, long searchNs, double throughput, long matchCount, string note)
    {
        Console.WriteLine(
            $"dotnet-regex,{model},{workload},{inputBytes},{iterations}," +
            $"{compileNs},{searchNs},{throughput:F2},{matchCount},{note}");
    }

    // --- per-model match functions (uniform signature) ---------------------

    /// count: leftmost, non-overlapping match count.
    private static int MCount(Regex re, string text)
    {
        int count = 0;
        for (Match m = re.Match(text); m.Success; m = m.NextMatch())
            count++;
        return count;
    }

    /// count-spans: sum of match lengths over the SAME match walk as count.
    private static int MSpans(Regex re, string text)
    {
        int sum = 0;
        for (Match m = re.Match(text); m.Success; m = m.NextMatch())
            sum += m.Length;
        return sum;
    }

    /// grep: number of lines (split on '\n') containing >=1 match. Empty lines
    /// never match our patterns.
    private static int MGrep(Regex re, string text) =>
        text.Split('\n').Count(line => re.IsMatch(line));

    /// count-captures: participating capture groups summed over all matches,
    /// group 0 (the whole match) excluded. Uses the regex's numeric group ids
    /// and counts a group iff it participated in that match.
    private static int MCaptures(Regex re, string text)
    {
        int[] groupNums = re.GetGroupNumbers().Where(g => g > 0).ToArray();
        int total = 0;
        for (Match m = re.Match(text); m.Success; m = m.NextMatch())
            foreach (int g in groupNums)
                if (m.Groups[g].Success) total++;
        return total;
    }

    /// Run one model: warm up, probe, size the timed loop to >=50 ms (5..500
    /// iterations), report the median. Identical methodology across harnesses.
    /// A RegexMatchTimeoutException during search emits a TIMEOUT row for
    /// model=count (mirroring the original single-model behaviour).
    private static void Measure(
        Func<Regex, string, int> f, string model, string workloadId,
        Regex re, string text, int byteLen, long compileMin)
    {
        int mc;
        try
        {
            _ = f(re, text); // warmup
            long p0 = NowNs();
            mc = f(re, text);
            long probe = Math.Max(NowNs() - p0, 1);

            int iters = (int)Math.Clamp(50_000_000L / probe, 5, 500);
            var samples = new long[iters];
            for (int i = 0; i < iters; i++)
            {
                long t0 = NowNs();
                _ = f(re, text);
                samples[i] = NowNs() - t0;
            }
            Array.Sort(samples);
            long median = samples[iters / 2];

            double mb = byteLen / 1_000_000.0;
            double secs = median / 1_000_000_000.0;
            double throughput = secs > 0.0 ? mb / secs : 0.0;

            EmitRow(model, workloadId, byteLen, iters, compileMin, median, throughput, mc, "ok");
        }
        catch (RegexMatchTimeoutException)
        {
            // Catastrophic backtracking on the default engine.
            EmitRow("count", workloadId, byteLen, 0, compileMin, -1, 0.00, -1, "TIMEOUT");
        }
    }

    /// Emit a REJECTED row for every model this workload would have run (keeps
    /// the per-model report sections consistent).
    private static void EmitRejected(in Workloads.W wl, int byteLen)
    {
        EmitRow("count", wl.Id, byteLen, 0, -1, -1, 0.00, -1, "REJECTED");
        if (wl.Spans) EmitRow("count-spans", wl.Id, byteLen, 0, -1, -1, 0.00, -1, "REJECTED");
        if (wl.Grep) EmitRow("grep", wl.Id, byteLen, 0, -1, -1, 0.00, -1, "REJECTED");
        if (wl.Captures) EmitRow("count-captures", wl.Id, byteLen, 0, -1, -1, 0.00, -1, "REJECTED");
    }

    private static void BenchOne(in Workloads.W wl, string text, int byteLen)
    {
        if (wl.ForceReject)
        {
            EmitRejected(wl, byteLen);
            return;
        }

        // --- compile timing (min over 50) and rejection handling ---
        const int compileIters = 50;
        long compileMin = long.MaxValue;
        for (int i = 0; i < compileIters; i++)
        {
            long t0 = NowNs();
            try
            {
                // Pattern is already in .NET's exact required form — pass straight.
                _ = new Regex(wl.Pattern, RegexOptions.None, Timeout);
            }
            catch (ArgumentException)
            {
                EmitRejected(wl, byteLen);
                return;
            }
            long dt = NowNs() - t0;
            if (dt < compileMin) compileMin = dt;
        }

        Regex re;
        try
        {
            re = new Regex(wl.Pattern, RegexOptions.None, Timeout);
        }
        catch (ArgumentException)
        {
            EmitRejected(wl, byteLen);
            return;
        }

        Measure(MCount, "count", wl.Id, re, text, byteLen, compileMin);
        if (wl.Spans) Measure(MSpans, "count-spans", wl.Id, re, text, byteLen, compileMin);
        if (wl.Grep) Measure(MGrep, "grep", wl.Id, re, text, byteLen, compileMin);
        if (wl.Captures) Measure(MCaptures, "count-captures", wl.Id, re, text, byteLen, compileMin);
    }

    /// regex-redux: compile every member pattern (min over 50 of compiling ALL
    /// members) and `count` each once over the corpus prefix, reporting total
    /// compile time, median total search time and the summed count. Its own
    /// report section; throughput is the aggregate bytes/s (members * bytes).
    private static void BenchRedux(string corpus)
    {
        string[] members = Workloads.ReduxMembers;
        if (members.Length == 0) return;
        int n = Math.Min(Workloads.ReduxSize, corpus.Length);
        string input = corpus.Substring(0, n);

        // --- compile timing: min over 50 of compiling ALL members ---
        long compileMin = long.MaxValue;
        for (int it = 0; it < 50; it++)
        {
            long t0 = NowNs();
            try
            {
                foreach (string m in members)
                    _ = new Regex(m, RegexOptions.None, Timeout);
            }
            catch (ArgumentException)
            {
                EmitRow("regex-redux", "redux", n, 0, -1, -1, 0.00, -1, "REJECTED");
                return;
            }
            long dt = NowNs() - t0;
            if (dt < compileMin) compileMin = dt;
        }

        // --- build once for the search loop ---
        Regex[] compiled;
        try
        {
            compiled = members.Select(m => new Regex(m, RegexOptions.None, Timeout)).ToArray();
        }
        catch (ArgumentException)
        {
            EmitRow("regex-redux", "redux", n, 0, -1, -1, 0.00, -1, "REJECTED");
            return;
        }

        int ReduxCount()
        {
            int t = 0;
            foreach (Regex r in compiled)
                t += MCount(r, input);
            return t;
        }

        try
        {
            int total = ReduxCount(); // warmup
            long p0 = NowNs();
            total = ReduxCount();
            long probe = Math.Max(NowNs() - p0, 1);

            int iters = (int)Math.Clamp(50_000_000L / probe, 5, 500);
            var samples = new long[iters];
            for (int i = 0; i < iters; i++)
            {
                long t0 = NowNs();
                _ = ReduxCount();
                samples[i] = NowNs() - t0;
            }
            Array.Sort(samples);
            long median = samples[iters / 2];

            double mb = (double)members.Length * n / 1_000_000.0;
            double secs = median / 1_000_000_000.0;
            double throughput = secs > 0.0 ? mb / secs : 0.0;
            EmitRow("regex-redux", "redux", n, iters, compileMin, median, throughput, total, "ok");
        }
        catch (RegexMatchTimeoutException)
        {
            EmitRow("regex-redux", "redux", n, 0, compileMin, -1, 0.00, -1, "TIMEOUT");
        }
    }

    private static int Main()
    {
        string path = Environment.GetEnvironmentVariable("CORPUS") ?? "corpus.txt";
        if (!File.Exists(path))
        {
            Console.Error.WriteLine($"cannot read corpus {path}");
            return 1;
        }
        string corpus = File.ReadAllText(path);

        // Dense synthetic log corpus for the `input: logs` workloads; falls back
        // to the mixed corpus if $LOGCORPUS is absent (manual single-engine runs).
        string logsPath = Environment.GetEnvironmentVariable("LOGCORPUS") ?? "logs.txt";
        string logs = File.Exists(logsPath) ? File.ReadAllText(logsPath) : corpus;

        string pathInput = new string('a', Workloads.SyntheticLen);

        foreach (ref readonly var wl in Workloads.All.AsSpan())
        {
            if (wl.Pathological)
            {
                BenchOne(wl, pathInput, pathInput.Length);
            }
            else
            {
                string src = wl.Logs ? logs : corpus;
                foreach (int sz in Workloads.CorpusSizes)
                {
                    int nn = Math.Min(sz, src.Length);
                    BenchOne(wl, src.Substring(0, nn), nn);
                }
            }
        }

        BenchRedux(corpus);
        return 0;
    }
}
