using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Minutes.Core;

public record NamedLine(double Start, string Speaker, string Text);
public static class Transcripts
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    public static bool ThaiJoins(byte[] before, string next)
    {
        var first = next.EnumerateRunes().FirstOrDefault().Value;
        if (first is 0xe30 or 0xe31 or 0xe32 or 0xe33 or 0xe45 or >= 0xe34 and <= 0xe3a or >= 0xe47 and <= 0xe4e) return true;
        var last = Encoding.UTF8.GetString(before).Trim().EnumerateRunes().LastOrDefault().Value;
        return last is >= 0xe40 and <= 0xe44 or 0xe31 or 0xe47;
    }
    private record Pending(int Index, int Token, double Start, int Speaker);
    public static IReadOnlyList<TranscriptLine> ParseWhisper(byte[] json, Func<double, int?>? speakerAt = null)
    {
        // whisper splits Thai UTF-8 across JSON token strings: preserve the raw byte values first.
        using var doc = JsonDocument.Parse(Encoding.Latin1.GetString(json));
        var lines = new List<TranscriptLine>(); var bytes = new List<byte>(); var ps = new List<double>();
        double start = 0, end = 0; int? speaker = null; Pending? pending = null;
        bool breakNext = false, afterSegment = false, afterSilence = false, movable = false;
        void Flush(byte[] text, double[] probabilities, double from, double to, int? voice) => lines.Add(new(from, to, Encoding.UTF8.GetString(text), voice, probabilities.Length == 0 ? null : probabilities.Average()));
        foreach (var piece in doc.RootElement.GetProperty("transcription").EnumerateArray())
        {
            var offsets = piece.GetProperty("offsets"); var from = offsets.GetProperty("from").GetDouble() / 1000; var to = offsets.GetProperty("to").GetDouble() / 1000;
            var tokens = piece.GetProperty("tokens").EnumerateArray().ToArray();
            var spoken = tokens.Where(t => !(t.GetProperty("text").GetString()!.StartsWith("[_", StringComparison.Ordinal) && t.GetProperty("text").GetString()!.EndsWith(']'))).ToArray();
            var text = spoken.SelectMany(t => t.GetProperty("text").GetString()!.EnumerateRunes().Select(r => (byte)(r.Value & 255))).ToArray();
            var endsSegment = tokens.Any(t => t.GetProperty("text").GetString()!.StartsWith("[_TT_", StringComparison.Ordinal));
            try
            {
                if (text.Length == 0) continue;
                var visible = Encoding.UTF8.GetString(text).Trim();
                var punctuation = visible.EnumerateRunes().All(Rune.IsPunctuation);
                var mark = visible.Length > 0 && Rune.GetUnicodeCategory(visible.EnumerateRunes().First()) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;
                var silence = from - end > 1;
                var voice = speakerAt?.Invoke(to - from > 1.5 ? (afterSegment ? to : from) : (from + to) / 2);
                var valid = true; try { StrictUtf8.GetString(bytes.ToArray()); } catch (DecoderFallbackException) { valid = false; }
                var breakable = !punctuation && !mark && valid && !(text[0] != (byte)' ' && ThaiJoins(bytes.ToArray(), visible));
                if (bytes.Count == 0) { start = from; speaker = voice; }
                else if (voice != null && speaker != null && voice != speaker && !breakNext && !silence && from - start < 1) speaker = voice;
                else if ((breakNext || silence) && breakable)
                {
                    Flush(bytes.ToArray(), ps.ToArray(), start, end, speaker); bytes.Clear(); ps.Clear(); start = from;
                    speaker = voice ?? pending?.Speaker ?? speaker; pending = null;
                    movable = afterSegment && !afterSilence && !silence; breakNext = afterSegment = afterSilence = false;
                }
                else if (silence) { breakNext = true; afterSilence = true; }
                if (voice != null && speaker != null && voice != speaker && bytes.Count > 0)
                {
                    if (pending == null && breakable && text[0] == (byte)' ') pending = new(bytes.Count, ps.Count, from, voice.Value);
                    if (pending is { } split && from - split.Start >= 3)
                    {
                        Flush(bytes.Take(split.Index).ToArray(), ps.Take(split.Token).ToArray(), start, split.Start, speaker);
                        bytes.RemoveRange(0, split.Index); ps.RemoveRange(0, split.Token); start = split.Start; speaker = split.Speaker; pending = null;
                    }
                }
                else if (voice != null && voice == speaker) pending = null;
                speaker ??= voice; bytes.AddRange(text);
                ps.AddRange(spoken.Where(t => t.TryGetProperty("p", out var p) && p.ValueKind == JsonValueKind.Number).Select(t => t.GetProperty("p").GetDouble()));
                if (to - from > 1.5)
                {
                    if (movable && from - start <= .5) start = to;
                    else { breakNext = true; afterSilence = true; }
                    movable = false;
                }
                if (visible.Length > 0 && ".?!".Contains(visible[^1])) breakNext = true;
                end = to;
            }
            finally { if (endsSegment) { breakNext = true; afterSegment = true; } }
        }
        if (bytes.Count > 0) Flush(bytes.ToArray(), ps.ToArray(), start, end, speaker);
        return lines.Select(l => l with { Text = l.Text.Trim() }).Where(l => l.Text.Length > 0).ToArray();
    }
    public static string[] Labels(IReadOnlyList<(int Track, int? Voice)> heard, IReadOnlyList<string> names)
    {
        var voices = heard.Where(h => h.Voice != null).GroupBy(h => h.Track).ToDictionary(g => g.Key, g => g.Select(h => h.Voice).Distinct().Count());
        var numbers = new Dictionary<(int, int), int>();
        return heard.Select(h =>
        {
            if (h.Voice is not { } voice || !voices.TryGetValue(h.Track, out var count) || count <= 1) return names[h.Track];
            var key = (h.Track, voice); if (!numbers.ContainsKey(key)) numbers[key] = numbers.Count + 1;
            return $"Speaker {numbers[key]}";
        }).ToArray();
    }
    public static string RenameSpeaker(string transcript,string old,string name)
    {
        if(string.IsNullOrWhiteSpace(name)||name.IndexOfAny(['\r','\n','*',':'])>=0)throw new ArgumentException("A speaker name cannot contain line breaks, stars or colons");
        return Regex.Replace(transcript,@"(?m)^(\*\*\[\d+:\d{2}:\d{2}\] )"+Regex.Escape(old)+@":\*\*",m=>m.Groups[1].Value+name.Trim()+":**");
    }
    public static string Clock(double t)
    {
        var total = (int)t; return $"{total / 3600:00}:{total / 60 % 60:00}:{total % 60:00}";
    }
    public static string Stamp(DateTimeOffset date) => date.LocalDateTime.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
    public static string Render(IReadOnlyList<NamedLine> lines, string title, DateTimeOffset startedAt, double seconds)
    {
        var output = new StringBuilder($"# {title}\n\n{Stamp(startedAt)} · {(int)Math.Round(seconds / 60, MidpointRounding.AwayFromZero)} min\n"); string? speaker = null;
        foreach (var l in lines)
        {
            output.Append(l.Speaker != speaker ? $"\n**[{Clock(l.Start)}] {l.Speaker}:** " : " "); output.Append(l.Text); speaker = l.Speaker;
        }
        if (lines.Count == 0) output.Append("\nNo speech detected.\n");
        return output.Append('\n').ToString();
    }
    public static IReadOnlyList<NamedLine> Parse(string markdown) => Regex.Matches(markdown, @"(?m)^\*\*\[(\d+):(\d{2}):(\d{2})\] (.+?):\*\* ([\s\S]*?)(?=\n\*\*\[|\z)")
        .Select(m => new NamedLine(int.Parse(m.Groups[1].Value) * 3600 + int.Parse(m.Groups[2].Value) * 60 + int.Parse(m.Groups[3].Value), m.Groups[4].Value, m.Groups[5].Value.Trim())).ToArray();
}
