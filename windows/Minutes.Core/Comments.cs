using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Minutes.Core;

public sealed class CommentMessage
{
    [JsonRequired]
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    [JsonRequired]
    public string Author { get; set; } = "";
    [JsonRequired]
    public string Text { get; set; } = "";
    [JsonRequired]
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset? EditedAt { get; set; }
    public bool? Claude { get; set; }
    public string? Model { get; set; }
    public Dictionary<string, string>? Revised { get; set; }
    public bool? Undone { get; set; }
}
public sealed class MeetingComment
{
    [JsonRequired]
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    [JsonRequired]
    public string Target { get; set; } = "summary";
    [JsonRequired]
    public string Quote { get; set; } = "";
    [JsonRequired]
    public string Prefix { get; set; } = "";
    [JsonRequired]
    public string Suffix { get; set; } = "";
    public double? LineTime { get; set; }
    [JsonRequired]
    public string Text { get; set; } = "";
    [JsonRequired]
    public string Author { get; set; } = "";
    [JsonRequired]
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset? EditedAt { get; set; }
    public List<CommentMessage>? Replies { get; set; }
    public DateTimeOffset? ResolvedAt { get; set; }
    public string? ResolvedBy { get; set; }
    public JsonElement? Reply { get; set; }
    public override string ToString() => $"{(ResolvedAt != null ? "✓ " : "")}{Author}: {Text}" + string.Concat((Replies ?? []).Select(r => "\n" + r.Author + ": " + r.Text + (r.Undone == true ? " (undone)" : "")));
}
public record CommentAnchor(int Unit, int Start, int Length);
public sealed class CommentDocument(IReadOnlyList<string?> units, IReadOnlyList<double>? times = null)
{
    public IReadOnlyList<string?> Units { get; } = units;
    public IReadOnlyList<double> Times { get; } = times ?? [];
    public string Full { get; } = string.Join("\n", units.Select(u => u ?? ""));
    public int Start(int unit) => Units.Take(unit).Sum(u => (u?.Length ?? 0) + 1);
    public CommentAnchor? Containing(int start, int length)
    {
        for (var i = 0; i < Units.Count; i++) if (Units[i] is { } text && start >= Start(i) && start + length <= Start(i) + text.Length) return new(i, start - Start(i), length);
        return null;
    }
    public CommentAnchor? Anchor(MeetingComment c)
    {
        if (c.Quote.Length == 0) return null;
        CommentAnchor? best = null; var score = -1;
        for (var index = 0; index <= Full.Length - c.Quote.Length;)
        {
            var found = Full.IndexOf(c.Quote, index, StringComparison.Ordinal); if (found < 0) break;
            if (Containing(found, c.Quote.Length) is { } anchor)
            {
                var before = Full[..found]; var after = Full[(found + c.Quote.Length)..];
                var s = before.Reverse().Zip(c.Prefix.Reverse()).TakeWhile(p => p.First == p.Second).Count() + after.Zip(c.Suffix).TakeWhile(p => p.First == p.Second).Count();
                if (c.LineTime is { } t && anchor.Unit < Times.Count && Math.Abs(Times[anchor.Unit] - t) < .5) s += 1000;
                if (s > score) { best = anchor; score = s; }
            }
            index = found + 1;
        }
        if (best != null || c.Prefix.Length < 8 || c.Suffix.Length < 8) return best;
        var head = c.Prefix[^Math.Min(16, c.Prefix.Length)..]; var tail = c.Suffix[..Math.Min(16, c.Suffix.Length)];
        var longest = Math.Max(c.Quote.Length * 2, c.Quote.Length + 40);
        for (var index = 0; index < Full.Length;)
        {
            var left = Full.IndexOf(head, index, StringComparison.Ordinal); if (left < 0) return null;
            var from = left + head.Length;
            var right = Full.IndexOf(tail, from, Math.Min(Full.Length - from, longest + tail.Length), StringComparison.Ordinal);
            if (right > from)
            {
                var text = Full[from..right]; var trimmed = text.Trim();
                if (trimmed.Length > 0 && Containing(from + text.Length - text.TrimStart().Length, trimmed.Length) is { } a) return a;
            }
            index = left + 1;
        }
        return null;
    }
}

public static class CommentRevision
{
    public record Edit(string? File, string Find, string Replace);
    public record Answer(string Reply, Edit[]? Edits = null, bool? Resolve = null);
    public static Answer Parse(string raw)
    {
        var start = raw.IndexOf('{'); var end = raw.LastIndexOf('}');
        if (start < 0 || end <= start) throw new InvalidDataException("The answer could not be read");
        return JsonSerializer.Deserialize<Answer>(raw[start..(end + 1)], JsonFiles.Options) ?? throw new InvalidDataException("Empty answer");
    }
    public static string TitleLine(string text) => text.IndexOf('\n') is var n && n >= 0 ? text[..(n + 1)] : text;
    public static string Body(string text) => text.IndexOf('\n') is var n && n >= 0 ? text[(n + 1)..] : "";
    public static string Hash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Body(text)))).ToLowerInvariant();
    public static IReadOnlyDictionary<string, string> Apply(IEnumerable<Edit> edits, IReadOnlyDictionary<string, string> documents, string defaultFile)
    {
        var revised = documents.ToDictionary(p => p.Key, p => p.Value);
        foreach (var edit in edits.Where(e => e.Find != e.Replace))
        {
            var name = edit.File ?? defaultFile;
            if (name is not ("summary.md" or "transcript.md") || !revised.TryGetValue(name, out var text)) throw new InvalidDataException("The meeting does not have that file");
            var first = edit.Find.Length == 0 ? -1 : text.IndexOf(edit.Find, StringComparison.Ordinal);
            if (first < 0) throw new InvalidDataException("The change did not match the text");
            if (text.IndexOf(edit.Find, first + 1, StringComparison.Ordinal) >= 0) throw new InvalidDataException("The change matched more than one place");
            revised[name] = text[..first] + edit.Replace + text[(first + edit.Find.Length)..];
        }
        foreach (var (name, text) in revised.Where(p => p.Value != documents[p.Key]))
        {
            var before = documents[name];
            if (TitleLine(text) != TitleLine(before)) throw new InvalidDataException("The title line changed");
            if (name == "transcript.md")
            {
                if (!Transcripts.Parse(text).Select(t => (t.Start, t.Speaker)).SequenceEqual(Transcripts.Parse(before).Select(t => (t.Start, t.Speaker)))) throw new InvalidDataException("The transcript's turns changed");
            }
            else if (Body(text).Trim().Length == 0) throw new InvalidDataException("Empty summary");
        }
        return revised;
    }
    public static void Save(string folder, CommentMessage reply, IReadOnlyDictionary<string, string> before, IReadOnlyDictionary<string, string> after)
    {
        var changed = after.Where(p => before[p.Key] != p.Value).ToArray();
        foreach (var (name, _) in changed) JsonFiles.AtomicWrite(SyncPlan.SafePath(folder, $"revisions/{reply.Id}-{name}"), before[name]);
        foreach (var (name, text) in changed) JsonFiles.AtomicWrite(Path.Combine(folder, name), text);
        reply.Revised = changed.ToDictionary(p => p.Key, p => Hash(p.Value));
    }
    public static void Undo(string folder, CommentMessage reply)
    {
        if (reply.Undone == true || reply.Revised == null) return;
        var restored = new Dictionary<string, string>();
        foreach (var (name, hash) in reply.Revised)
        {
            if (name is not ("summary.md" or "transcript.md")) throw new InvalidDataException("Unknown revision file");
            var now = System.IO.File.ReadAllText(Path.Combine(folder, name));
            if (Hash(now) != hash) throw new InvalidOperationException("The text has changed since this reply");
            var path = SyncPlan.SafePath(folder, $"revisions/{reply.Id}-{name}");
            if (!System.IO.File.Exists(path)) path = SyncPlan.SafePath(folder, $"revisions/{reply.Id}.md");
            restored[name] = TitleLine(now) + Body(System.IO.File.ReadAllText(path));
        }
        foreach (var (name, text) in restored) JsonFiles.AtomicWrite(Path.Combine(folder, name), text);
        reply.Undone = true;
    }
}
