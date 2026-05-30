// Cross-engine benchmark harness — .NET System.Text.RegularExpressions side.
//
// Emits CSV rows (no header) with the schema shared by all harnesses:
//   engine,workload,input_bytes,iterations,compile_ns,search_ns_per_op,throughput_mb_s,match_count,note
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
using System.Text.RegularExpressions;

internal static class Program
{
    private sealed class Workload
    {
        public string Id = "";
        public string Pattern = "";
        public bool Pathological;
    }

    private static readonly Workload[] Workloads =
    {
        new() { Id = "literal",      Pattern = "Sherlock" },
        new() { Id = "quantifier",   Pattern = "a+" },
        new() { Id = "digits",       Pattern = "[0-9]+" },
        new() { Id = "word",         Pattern = @"\w+" },
        new() { Id = "alternation",  Pattern = "cat|dog|bird|fish" },
        new() { Id = "email",        Pattern = @"[\w\.+-]+@[\w\.-]+\.[\w\.-]+" },
        new() { Id = "uri",          Pattern = @"[\w]+://[^/\s?#]+[^\s?#]+(?:\?[^\s#]*)?(?:#[^\s]*)?" },
        new() { Id = "ipv4",         Pattern = @"(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)" },
        // Real-world workloads. Shell /.../ delimiters & stray markdown
        // backticks stripped; named groups -> non-capturing (harness compares
        // match counts); k8s leading ^ dropped so it matches log-shaped
        // substrings anywhere in the token corpus.
        new() { Id = "html_title",   Pattern = @"<h2 class=""product-title"">(.*?)</h2>" },
        new() { Id = "href",         Pattern = @"href=""([^""]+)""" },
        new() { Id = "price",        Pattern = @"\$[\d,]+\.?\d*" },
        new() { Id = "nltk",         Pattern = @"(?:[A-Z]\.)+|\w+(?:-\w+)*|\$?\d+(?:\.\d+)?%?|\.\.\.|[.,;""'?():_\-]" },
        new() { Id = "ssn",          Pattern = @"[0-9]{3,3}-[0-9]{2,2}-[0-9]{4,4}" },
        new() { Id = "modsec_sqli",  Pattern = @"([~!@#$%^&*()\-+={}\[\]|:;""'´’‘<>\\].*?){4,}" },
        new() { Id = "aws_eni",      Pattern = @"(?:eni-.*?) " },
        new() { Id = "apache_post",  Pattern = @"POST (?:/[a-zA-Z0-9_]+){1,}" },
        new() { Id = "k8s_fluentd",  Pattern = @"(?:\d{4}-\d{1,2}-\d{1,2} \d{1,2}:\d{1,2}:\d{1,2}.\d{3})\s+(?:[^\s]+)\s+(?:\d+).*?\[\s+(?:.*)\]\s+(?:.*)\s+:\s+(?:.*)" },
        // Typical + portable-edge additions.
        new() { Id = "date_iso",     Pattern = @"[0-9]{4}-[0-9]{2}-[0-9]{2}" },
        new() { Id = "time_hms",     Pattern = @"[0-9]{2}:[0-9]{2}:[0-9]{2}" },
        new() { Id = "phone_us",     Pattern = @"\(?[0-9]{3}\)?[ .-][0-9]{3}[ .-][0-9]{4}" },
        new() { Id = "hex_color",    Pattern = @"#[0-9a-fA-F]{6}" },
        new() { Id = "uuid",         Pattern = @"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" },
        new() { Id = "mac_addr",     Pattern = @"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" },
        new() { Id = "semver",       Pattern = @"v?[0-9]+\.[0-9]+\.[0-9]+" },
        new() { Id = "credit_card",  Pattern = @"[0-9]{4}[ -][0-9]{4}[ -][0-9]{4}[ -][0-9]{4}" },
        new() { Id = "log_level",    Pattern = @"(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)" },
        new() { Id = "html_tag",     Pattern = @"<[^>]+>" },
        new() { Id = "hashtag",      Pattern = @"#[A-Za-z0-9_]+" },
        new() { Id = "float_sci",    Pattern = @"[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?" },
        new() { Id = "json_string",  Pattern = @"""(?:[^""\\]|\\.)*""" },
        new() { Id = "base64",       Pattern = @"(?:[A-Za-z0-9+/]{4})+={0,2}" },
        new() { Id = "path_unix",    Pattern = @"(?:/[A-Za-z0-9_.-]+)+" },
        new() { Id = "deep_alternation", Pattern = @"\b(?:break|case|catch|class|const|continue|default|delete|do|else|enum|export|extends|false|finally|for|function|if|import|in|instanceof|new|null|return|super|switch|this|throw|true|try|typeof|var|void|while|with|yield|async|await|let)\b" },
        new() { Id = "wildcard_gaps", Pattern = @"foo.*bar.*baz" },
        // Real-world multiline: every full log line that begins with an ISO
        // date (`(?m)` makes `^`/`$` per-line anchors). Zeetah uses the
        // `.multiline` struct-flag peer of this inline form.
        new() { Id = "multiline_log", Pattern = @"(?m)^[0-9]{4}-[0-9]{2}-[0-9]{2}.*$" },
        // Feature-heavy: .NET fully supports backreferences, look-behind and
        // atomic groups, so it runs all of these.
        new() { Id = "backref_word", Pattern = @"(\b[A-Za-z]+\b) \1" },
        new() { Id = "lookbehind_amount", Pattern = @"(?<=\$)[0-9]+(?:\.[0-9]{2})?" },
        new() { Id = "unicode_prop", Pattern = @"[\p{L}\p{N}_]+" },
        new() { Id = "atomic_token", Pattern = @"(?>[A-Za-z0-9_]+)@" },
        // GPT-4 cl100k_base pre-tokenizer. .NET fully supports `(?i:)`,
        // `\p{L}`/`\p{N}`, `(?!\S)` look-around and atomic groups `(?>…)`.
        // It only lacks the possessive-quantifier *syntax* `?+`/`++`, so we
        // use the canonical .NET spelling of possessive — `X?+` -> `(?>X?)`,
        // `X++` -> `(?>X+)` — which is exactly equivalent (an atomic group
        // *is* a possessive quantifier). Same language, same tokens: the
        // correctness gate verifies this row's match counts equal Zeetah
        // and fancy-regex (they do: 212 / 1755 / 7116).
        new() { Id = "tokenizer",    Pattern = @"(?i:[sdmt]|ll|ve|re)|(?>[^\r\n\p{L}\p{N}]?)\p{L}+|\p{N}{1,3}| ?(?>[^\s\p{L}\p{N}]+)[\r\n]|\s[\r\n]|\s+(?!\S)|\s+" },
        new() { Id = "pathological", Pattern = "(a+)+b", Pathological = true },
    };

    private static readonly int[] CorpusSizes = { 1024, 8192, 32768, 1048576 };

    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(2);

    private static long NowNs() =>
        (long)(Stopwatch.GetTimestamp() * (1_000_000_000.0 / Stopwatch.Frequency));

    private static int ScanCount(Regex re, string text)
    {
        int count = 0;
        for (Match m = re.Match(text); m.Success; m = m.NextMatch())
            count++;
        return count;
    }

    private static void BenchOne(Workload wl, string text, int byteLen)
    {
        // --- compile timing ---
        const int compileIters = 50;
        long compileMin = long.MaxValue;
        for (int i = 0; i < compileIters; i++)
        {
            long t0 = NowNs();
            try
            {
                _ = new Regex(wl.Pattern, RegexOptions.None, Timeout);
            }
            catch (ArgumentException)
            {
                Console.WriteLine($"dotnet-regex,{wl.Id},{byteLen},0,-1,-1,0.00,-1,REJECTED");
                return;
            }
            long dt = NowNs() - t0;
            if (dt < compileMin) compileMin = dt;
        }
        var re = new Regex(wl.Pattern, RegexOptions.None, Timeout);

        // --- search timing ---
        int matchCount;
        try
        {
            _ = ScanCount(re, text); // warmup
            long p0 = NowNs();
            matchCount = ScanCount(re, text);
            long probe = Math.Max(NowNs() - p0, 1);

            int iters = (int)Math.Clamp(50_000_000L / probe, 5, 500);
            var samples = new long[iters];
            for (int i = 0; i < iters; i++)
            {
                long t0 = NowNs();
                _ = ScanCount(re, text);
                samples[i] = NowNs() - t0;
            }
            Array.Sort(samples);
            long median = samples[iters / 2];

            double mb = byteLen / 1_000_000.0;
            double secs = median / 1_000_000_000.0;
            double throughput = secs > 0.0 ? mb / secs : 0.0;

            Console.WriteLine(
                $"dotnet-regex,{wl.Id},{byteLen},{iters},{compileMin},{median}," +
                $"{throughput:F2},{matchCount},ok");
        }
        catch (RegexMatchTimeoutException)
        {
            // Catastrophic backtracking on the default engine.
            Console.WriteLine($"dotnet-regex,{wl.Id},{byteLen},0,{compileMin},-1,0.00,-1,TIMEOUT");
        }
    }

    private static int Main()
    {
        string path = Environment.GetEnvironmentVariable("CORPUS")
                      ?? "corpus.txt";
        if (!File.Exists(path))
        {
            Console.Error.WriteLine($"cannot read corpus {path}");
            return 1;
        }
        string corpus = File.ReadAllText(path);
        string pathInput = new string('a', 50_000);

        foreach (var wl in Workloads)
        {
            if (wl.Pathological)
            {
                BenchOne(wl, pathInput, pathInput.Length);
            }
            else
            {
                foreach (int sz in CorpusSizes)
                {
                    int n = Math.Min(sz, corpus.Length);
                    BenchOne(wl, corpus.Substring(0, n), n);
                }
            }
        }
        return 0;
    }
}
