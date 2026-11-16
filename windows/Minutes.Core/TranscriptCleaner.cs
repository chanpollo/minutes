using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Minutes.Core;

public record TranscriptLine(double Start, double End, string Text, int? Voice = null, double? P = null);
public sealed class CleanResult
{
    public List<TranscriptLine> Lines { get; set; } = [];
    public int Collapsed, Dropped, Runs, Repeats, Fragments, Fillers;
    public List<(double From, double To)> Retried { get; } = [];
}

public static class TranscriptCleaner
{
    public const double FillerProbability = .5, RecurrenceWindow = 120, StretchGap = 10, CopyShare = .6;
    public const int LongPhrase = 10, FragmentFloor = 4, LongRun = 6, CopyMinimum = 8;
    private static readonly string[] Fillers = ["Thank you.", "Thanks for watching.", "ขอบคุณครับ", "ขอบคุณค่ะ", "ติดตามชมตอนต่อไป"];
    private static readonly string[] FillerPrefixes = ["บรรยายโดย", "Subtitles by"];
    private static readonly Regex WordLoop = new(@"(?<!\S)(\S+(?:\s+\S+)+?)(?:\s+\1){2,}(?!\S)");
    private static readonly Regex TokenLoop = new(@"(?<!\S)(\S+)(?:\s+\1){5,}(?!\S)");
    private static readonly Regex CharacterLoop = new(@"(\S{6,}?)(?:\s*\1){2,}");
    public static string Normalise(string text) => string.Concat(text.ToLowerInvariant().EnumerateRunes().Where(r => !Rune.IsWhiteSpace(r) && !Rune.IsPunctuation(r)).Select(r => r.ToString()));
    private static int Count(string text) => text.Elements().Length;
    public record Collapsed(string Text, string? Phrase, bool OnlyPhrase);
    public static Collapsed Collapse(string text)
    {
        string? phrase = null;
        var output = text;
        foreach (var regex in new[] { WordLoop, TokenLoop })
        {
            var m = regex.Match(output);
            if (m.Success) { phrase ??= m.Groups[1].Value; output = regex.Replace(output, "$1"); }
        }
        foreach (Match match in CharacterLoop.Matches(output).Cast<Match>().Reverse())
        {
            if (!match.Groups[1].Value.Any(c => c is >= '\u0e00' and <= '\u0e7f')) continue;
            var repeated = Period(match.Groups[1].Value);
            var end = match.Index + match.Length;
            while (output.AsSpan(end).StartsWith(repeated, StringComparison.Ordinal)) end += repeated.Length;
            output = output[..match.Index] + repeated + output[end..]; phrase = repeated;
        }
        if (phrase == null) return new(output, null, false);
        var said = Normalise(output); var unit = Normalise(phrase);
        return new(output, phrase, said.Length == 0 || (unit + unit + unit).Contains(said, StringComparison.Ordinal));
    }
    private static string Period(string text)
    {
        var chars = text.Elements();
        for (var d = 1; d < chars.Length; d++)
            if (chars.Length % d == 0 && Enumerable.Range(d, chars.Length - d).All(i => chars[i] == chars[i % d])) return string.Concat(chars.Take(d));
        return text;
    }
    public static bool IsFiller(string text)
    {
        var said = Normalise(Collapse(text).Text);
        return said.Length > 0 && (Fillers.Any(f => Normalise(f) == said) || FillerPrefixes.Any(f => said.StartsWith(Normalise(f), StringComparison.Ordinal)));
    }
    public static bool AboveFloor(string text) => Regex.Split(text.Trim(), @"\s+").Length >= 2 || Count(Normalise(text)) >= 6;
    private sealed class Mark(TranscriptLine original)
    {
        public TranscriptLine Original = original;
        public TranscriptLine? Line = original;
        public bool Bad;
        public string? AnchorKey;
    }
    private record Anchor(string Key, double From, double To, bool Exact = false)
    {
        public bool Long => Count(Key) >= LongPhrase;
        public bool Covers(TranscriptLine line) => From <= line.Start && line.Start <= To;
    }
    public static CleanResult Clean(IEnumerable<TranscriptLine> lines, Func<double, double, IReadOnlyList<TranscriptLine>>? rerun = null) => CleanInternal(lines, rerun, []);
    private static CleanResult CleanInternal(IEnumerable<TranscriptLine> lines, Func<double, double, IReadOnlyList<TranscriptLine>>? rerun, IReadOnlyList<string> known)
    {
        var result = new CleanResult();
        var marked = lines.Select(l => new Mark(l)).ToList();
        var anchors = known.Select(k => new Anchor(k, double.NegativeInfinity, double.PositiveInfinity, true)).ToList();
        foreach (var mark in marked)
        {
            var line = mark.Original; var cut = Collapse(line.Text);
            if (cut.Phrase != null)
            {
                result.Collapsed++; mark.Bad = true;
                if (cut.OnlyPhrase && (line.P ?? 1) < FillerProbability) { result.Dropped++; mark.Line = null; }
                else mark.Line = line with { Text = cut.Text };
                mark.AnchorKey = Normalise(cut.Phrase);
                anchors.Add(new(mark.AnchorKey, line.Start - RecurrenceWindow, line.End + RecurrenceWindow));
            }
            else if (IsFiller(line.Text) && (line.P ?? 1) < FillerProbability) { result.Fillers++; mark.Bad = true; mark.Line = null; }
        }
        for (var i = 0; i < marked.Count;)
        {
            if (marked[i].Line is not { } first) { i++; continue; }
            var key = Normalise(first.Text); var j = i;
            while (j + 1 < marked.Count && marked[j + 1].Line is { } next && Normalise(next.Text) == key && next.Start - marked[j].Original.End <= RecurrenceWindow) j++;
            if (j - i >= 2 && key.Length > 0 && (AboveFloor(first.Text) || marked.Skip(i).Take(j - i + 1).All(m => m.Bad) || j - i + 1 >= LongRun))
            {
                result.Runs++;
                for (var k = i; k <= j; k++) { marked[k].Bad = true; if (k > i) marked[k].Line = null; }
                marked[i].AnchorKey = key; anchors.Add(new(key, first.Start - RecurrenceWindow, marked[j].Original.End + RecurrenceWindow));
            }
            i = j + 1;
        }
        var groups = marked.Select((m, i) => (m, i)).Where(x => x.m.Line != null && AboveFloor(x.m.Line.Text))
            .GroupBy(x => Normalise(x.m.Line!.Text)).Where(g => g.Key.Length > 0).OrderBy(g => g.First().i);
        foreach (var group in groups)
        {
            var indices = group.Select(x => x.i).ToArray(); var chains = new List<List<int>>();
            if (Count(group.Key) >= LongPhrase && indices.Length >= 3) chains.Add([.. indices]);
            else
            {
                var chain = new List<int> { indices[0] };
                foreach (var k in indices.Skip(1))
                {
                    if (marked[k].Original.Start - marked[chain[^1]].Original.End <= RecurrenceWindow) chain.Add(k);
                    else { if (chain.Count >= 3) chains.Add(chain); chain = [k]; }
                }
                if (chain.Count >= 3) chains.Add(chain);
            }
            foreach (var chain in chains)
            {
                foreach (var k in chain) { marked[k].Bad = true; if (k != chain[0]) { marked[k].Line = null; result.Repeats++; } }
                marked[chain[0]].AnchorKey = group.Key;
                anchors.Add(new(group.Key, Count(group.Key) >= LongPhrase ? double.NegativeInfinity : marked[chain[0]].Original.Start - RecurrenceWindow,
                    Count(group.Key) >= LongPhrase ? double.PositiveInfinity : marked[chain[^1]].Original.End + RecurrenceWindow));
            }
        }
        var longs = anchors.Where(a => a.Long).ToArray();
        foreach (var mark in marked)
        {
            if (mark.Line is not { } line) continue;
            var said = Normalise(line.Text);
            if (Count(said) < FragmentFloor) continue;
            if (longs.Any(a => a.Covers(line) && a.Key != mark.AnchorKey && (said == a.Key ? a.Exact : a.Key.Contains(said, StringComparison.Ordinal) || mark.AnchorKey == null && said.Contains(a.Key, StringComparison.Ordinal))))
            { result.Fragments++; mark.Bad = true; mark.Line = null; }
        }
        if (rerun != null)
        {
            var spans = new List<(int Start, int End)>();
            for (var k = 0; k < marked.Count;)
            {
                if (!marked[k].Bad) { k++; continue; }
                var end = k; var count = 1;
                for (var next = end + 1; next < marked.Count; next++)
                {
                    if (!marked[next].Bad) continue;
                    if (marked[next].Original.Start - marked[end].Original.End > StretchGap) break;
                    end = next; count++;
                }
                if (count >= 3) spans.Add((k, end + 1)); k = end + 1;
            }
            foreach (var span in spans.AsEnumerable().Reverse())
            {
                var from = Math.Max(0, marked[span.Start].Original.Start - 5); var to = marked[span.End - 1].Original.End + 5;
                IReadOnlyList<TranscriptLine> again;
                try { again = rerun(from, to); } catch (OperationCanceledException) { throw; } catch (IOException) { continue; }
                result.Retried.Insert(0, (from, to));
                var before = marked.Take(span.Start).LastOrDefault(m => m.Line != null)?.Original.End ?? 0;
                var after = marked.Skip(span.End).FirstOrDefault(m => m.Line != null)?.Original.Start ?? double.PositiveInfinity;
                var fresh = CleanInternal(again, null, longs.Select(a => a.Key).ToArray()).Lines.Where(l => l.Start >= before - .5 && l.Start < after - .5).Select(l => new Mark(l)).ToArray();
                marked.RemoveRange(span.Start, span.End - span.Start); marked.InsertRange(span.Start, fresh);
            }
        }
        result.Lines = marked.Where(m => m.Line != null).Select(m => m.Line!).ToList(); return result;
    }
    public static HashSet<string> Trigrams(string text)
    {
        var chars = text.Elements();
        return chars.Length < 3 ? (chars.Length == 0 ? [] : [text]) : Enumerable.Range(0, chars.Length - 2).Select(i => string.Concat(chars.Skip(i).Take(3))).ToHashSet(StringComparer.Ordinal);
    }
    public static (IReadOnlyList<TranscriptLine> Kept, int Dropped) Dedupe(IReadOnlyList<TranscriptLine> me, IReadOnlyList<TranscriptLine> others, double tolerance = 3)
    {
        var far = others.Select(l => (Line: l, Grams: Trigrams(Normalise(l.Text)))).Where(x => x.Grams.Count > 0).ToArray();
        var kept = me.Where(l =>
        {
            var said = Normalise(l.Text); if (Count(said) < CopyMinimum) return true;
            var grams = Trigrams(said);
            return !far.Any(o => l.Start <= o.Line.End + tolerance && o.Line.Start <= l.End + tolerance && grams.Intersect(o.Grams).Count() >= CopyShare * grams.Count);
        }).ToArray();
        return (kept, me.Count - kept.Length);
    }
    public static (IReadOnlyList<TranscriptLine> Kept, int Dropped) DropLeak(IReadOnlyList<TranscriptLine> me, IReadOnlyList<TranscriptLine> others, IReadOnlyList<(double From, double To)> retried, double tolerance = 3)
    {
        var kept = me.Where(l => !retried.Any(r => r.From <= l.Start && l.Start <= r.To) || !others.Any(o => l.Start <= o.End + tolerance && o.Start <= l.End + tolerance)).ToArray();
        return (kept, me.Count - kept.Length);
    }
}
