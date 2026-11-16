using System.Reflection;
using System.Text.RegularExpressions;

namespace Minutes.Core;

public record CalendarEvent(string Title, DateTimeOffset Start, DateTimeOffset End, string Text = "", string[]? Attendees = null, bool HasExternal = false, bool IsAllDay = false, bool IsCancelled = false, bool DeclinedByMe = false);
public record VideoFrame(double Time, string File, string Text);
public static class SummaryPrompts
{
    public static string Resource(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream($"Minutes.Core.Prompts.{name}.txt") ?? throw new IOException("Missing prompt " + name);
        using var read = new StreamReader(stream); return read.ReadToEnd().Replace("\r\n", "\n", StringComparison.Ordinal);
    }
    private static string Sections(bool thai)
    {
        var words = thai ? new[] { "สรุป", "สิ่งที่ตัดสินใจ", "Action items", "งาน", "ผู้รับผิดชอบ", "กำหนด", "เวลา", "ไม่มี", "ไม่ระบุ" }
            : ["Summary", "Decisions", "Action items", "Task", "Owner", "Due", "Time", "None", "Not stated"];
        var keys = new[] { "summary", "decisions", "actions", "task", "owner", "due", "time", "none", "unnamed" };
        var text = Resource("sections");
        for (var i = 0; i < keys.Length; i++) text = text.Replace("\\(w." + keys[i] + ")", words[i], StringComparison.Ordinal);
        return text;
    }
    public static string Prompt(string language = "thai", bool pictures = false, bool voice = false, bool events = false)
    {
        var intro = Resource("intro") + (voice ? Resource("voice") : "") + Resource("invited") + (events ? Resource("eventsNote") : "") + (pictures ? Resource("picturesNote") : "");
        var rules = "Keep product names, people's names and technical terms in their original language. " + (events ? "After the Event line, output" : "Output") + " exactly the three sections below in this order and nothing else: no preamble, no closing remarks, no other headings.";
        return language switch
        {
            "thai" => intro + "Write in Thai. " + rules + "\n\n" + Sections(true),
            "english" => intro + "Write in English. " + rules + "\n\n" + Sections(false),
            "meeting" => intro + $"Write in the language most of the meeting was spoken in. {rules} When that language is Thai, use the Thai headings and words below; otherwise use the English ones from the second copy, with the text in the meeting's language.\n\n{Sections(true)}\n\nSecond copy, for any other language:\n\n{Sections(false)}",
            _ => throw new ArgumentException("Unknown summary language", nameof(language))
        };
    }
    public static IReadOnlyList<CalendarEvent> ChoosableEvents(MeetingMeta meta, IReadOnlyList<CalendarEvent> events) => meta.Note == true || meta.EventPicked == true || events.Count < 2 || !events.Any(e => e.Title == meta.Title) ? [] : events.Where(e => e.Title == meta.Title).Concat(events.Where(e => e.Title != meta.Title)).ToArray();
    public static (int? Index, string Text) ChosenEvent(string reply, int count)
    {
        if (count < 2) return (null, reply);
        var trimmed = reply.TrimStart(); var end = trimmed.IndexOfAny(['\r', '\n']); if (end < 0) end = trimmed.Length;
        var line = trimmed[..end].Trim(); if (!line.StartsWith("event:", StringComparison.OrdinalIgnoreCase)) return (null, reply);
        return (int.TryParse(line[6..].Trim(), out var n) && n > 1 && n <= count ? n - 1 : null, trimmed[end..]);
    }
    public static string EventList(IReadOnlyList<CalendarEvent> events) => "Calendar events on when the recording began:\n" + string.Join("\n", events.Select((e, i) => $"{i + 1}. {e.Title} ({e.Start.LocalDateTime:HH:mm}–{e.End.LocalDateTime:HH:mm})" + (e.Attendees?.Length > 0 ? " · Invited: " + string.Join(", ", e.Attendees) : ""))) + "\n";
    public static string Pictures(IReadOnlyList<VideoFrame> frames, int perFrame = 400, int total = 8000)
    {
        if (frames.Count == 0) return "";
        var output = "Pictures from the meeting's screen video:\n";
        foreach (var frame in frames)
        {
            var text = string.Join(" / ", frame.Text.Split(['\r', '\n']).Select(l => l.Trim()).Where(l => l.Length > 0));
            var chars = text.Elements(); if (chars.Length > perFrame) text = string.Concat(chars.Take(perFrame)) + "…";
            var entry = $"[{Transcripts.Clock(frame.Time)}] {frame.File}: {(text.Length == 0 ? "(no text)" : text)}\n";
            if ((output + entry).Elements().Length > total) break;
            output += entry;
        }
        return output;
    }
    public static string KeepKnownPictures(string markdown, ISet<string> known, int limit = 6)
    {
        var used = new HashSet<string>(StringComparer.Ordinal); var lines = new List<string>();
        foreach (var line in markdown.Split('\n'))
        {
            var dropped = false;
            var kept = Regex.Replace(line, @"!\[[^\]\n]*\]\((frames/[^)\s]+)\)", m =>
            {
                var path = m.Groups[1].Value;
                if (known.Contains(path) && used.Count < limit && used.Add(path)) return m.Value;
                dropped = true; return "";
            });
            if (dropped && kept.Trim().Length == 0) continue;
            lines.Add(dropped ? kept.TrimEnd(' ', '\t') : kept);
        }
        return string.Join("\n", lines);
    }
}
