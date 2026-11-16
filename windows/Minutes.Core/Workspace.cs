using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Minutes.Core;

public sealed class MeetingMeta
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Title { get; set; } = "Untitled";
    public DateTimeOffset StartedAt { get; set; } = DateTimeOffset.Now;
    public DateTimeOffset? EndedAt { get; set; }
    public string? App { get; set; }
    public string? BundleID { get; set; }
    public string? Mode { get; set; }
    public string[]? Attendees { get; set; }
    public bool? EventPicked { get; set; }
    public double? VideoOffset { get; set; }
    public string? TranscriptError { get; set; }
    public string? SummaryModel { get; set; }
    public DateTimeOffset? SummarizedAt { get; set; }
    public string? GroupID { get; set; }
    public bool? Confidential { get; set; }
    public bool? SentAnyway { get; set; }
    public DateTimeOffset? VideoDeletedAt { get; set; }
    public DateTimeOffset? AudioDeletedAt { get; set; }
    public DateTimeOffset? PinnedAt { get; set; }
    public DateTimeOffset? ArchivedAt { get; set; }
    public bool? Note { get; set; }
    public JsonElement? Drive { get; set; }
    public JsonElement? Sync { get; set; }
    public JsonElement? Briefing { get; set; }
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    [JsonIgnore] public string RecordMode => Modes.Read(Mode);
    [JsonIgnore] public bool IsNote => Note == true && Mode == null;
}

public static class Modes
{
    public static string Read(string? value) => value switch
    {
        null or "screen" or "call" => "screen",
        "voice" or "inPerson" => "voice",
        _ => throw new JsonException($"Unknown record mode {value}")
    };
    public static bool SeparatesMic(MeetingMeta meta) => meta.RecordMode == "voice" && meta.App == null && meta.BundleID == null;
}

public record MeetingGroup(string Id, string Name);
public record Meeting(string Folder, MeetingMeta Meta)
{
    public override string ToString() => $"{(Meta.PinnedAt != null ? "📌 " : "")}{Meta.Title}";
}

public static class JsonFiles
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new SwiftDateConverter() },
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };
    public static T? Read<T>(string path) => JsonSerializer.Deserialize<T>(File.ReadAllText(path), Options);
    public static void Write<T>(string path, T value) => AtomicWrite(path, JsonSerializer.Serialize(value, Options));
    public static void AtomicWrite(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".partial";
        try { File.WriteAllText(temporary, text, new System.Text.UTF8Encoding(false)); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

public sealed class Workspace(string root)
{
    private readonly object gate = new();
    public string Root { get; } = Path.GetFullPath(root);
    public static string CleanTitle(string title)
    {
        // Windows forbids additional filename characters and trailing dots.
        var clean = Regex.Replace(title, "[/:\\\\\n\r\t<>\"|?*]", "-").Trim().TrimEnd('.');
        return string.IsNullOrEmpty(clean) ? "Meeting" : string.Concat(System.Globalization.StringInfo.GetTextElementEnumerator(clean).AsElements().Take(80));
    }
    public static string FolderName(string title, DateTimeOffset date) => $"{date.LocalDateTime.ToString("yyyy-MM-dd HHmm", CultureInfo.InvariantCulture)} {CleanTitle(title)}";
    public static string UniquePath(string root, string name)
    {
        var path = Path.Combine(root, name);
        for (var n = 2; Directory.Exists(path) || File.Exists(path); n++) path = Path.Combine(root, $"{name} {n}");
        return path;
    }
    public static MeetingMeta? ReadMeta(string folder)
    {
        try { using var document=JsonDocument.Parse(File.ReadAllText(Path.Combine(folder,"meta.json")));var value=document.RootElement;
            if(!value.TryGetProperty("id",out var id)||id.ValueKind!=JsonValueKind.String||!value.TryGetProperty("title",out var title)||title.ValueKind!=JsonValueKind.String||!value.TryGetProperty("startedAt",out var started)||started.ValueKind!=JsonValueKind.String)return null;
            var m = JsonFiles.Read<MeetingMeta>(Path.Combine(folder, "meta.json")); if (m != null && m.Mode != null) m.Mode = Modes.Read(m.Mode); return m; }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }
    public static void WriteMeta(string folder, MeetingMeta meta) => JsonFiles.Write(Path.Combine(folder, "meta.json"), meta);
    public IReadOnlyList<Meeting> Meetings() => !Directory.Exists(Root) ? [] : Directory.EnumerateDirectories(Root)
        .Where(p => !Path.GetFileName(p).StartsWith('.')).Select(p => new Meeting(p, ReadMeta(p)!)).Where(m => m.Meta != null).OrderByDescending(m => m.Meta.StartedAt).ToArray();
    public Meeting? Find(string id) => Meetings().FirstOrDefault(m => m.Meta.Id == id);
    public MeetingMeta Update(string folder, Action<MeetingMeta> change)
    {
        lock (gate) { var meta = ReadMeta(folder) ?? throw new IOException("Meeting metadata is missing"); change(meta); WriteMeta(folder, meta); return meta; }
    }
    public Meeting MakeNote(string? groupID = null)
    {
        lock (gate)
        {
            Directory.CreateDirectory(Root);
            var meta = new MeetingMeta { Note = true, GroupID = groupID, EndedAt = DateTimeOffset.Now };
            var folder = UniquePath(Root, FolderName(meta.Title, meta.StartedAt));
            Directory.CreateDirectory(folder); WriteMeta(folder, meta); JsonFiles.AtomicWrite(Path.Combine(folder, "notes.md"), "");
            return new(folder, meta);
        }
    }
    public Meeting Rename(Meeting meeting, string title)
    {
        lock (gate)
        {
            var old = meeting.Meta.Title;
            var meta = Update(meeting.Folder, m => m.Title = title.Trim());
            var folder = meeting.Folder;
            var name = FolderName(meta.Title, meta.StartedAt);
            if (!string.Equals(name, Path.GetFileName(folder), StringComparison.Ordinal))
            {
                var target = UniquePath(Root, name); Directory.Move(folder, target); folder = target;
            }
            foreach (var file in new[] { "summary.md", "transcript.md" })
            {
                var p = Path.Combine(folder, file);
                if (File.Exists(p) && Retitled(File.ReadAllText(p), old, meta.Title) is { } text) JsonFiles.AtomicWrite(p, text);
            }
            if(File.Exists(Path.Combine(folder,"comments.json")))CommentFiles.Save(folder,CommentFiles.Read(folder),meta.Title);
            return new(folder, meta);
        }
    }
    public static string? Retitled(string text, string old, string title)
    {
        var head = "# " + old;
        return text == head || text.StartsWith(head + "\n", StringComparison.Ordinal) || text.StartsWith(head + "\r\n", StringComparison.Ordinal) ? "# " + title + text[head.Length..] : null;
    }
    public IReadOnlyList<MeetingGroup> Groups() => File.Exists(Path.Combine(Root, "groups.json")) ? JsonFiles.Read<MeetingGroup[]>(Path.Combine(Root, "groups.json")) ?? [] : [];
    public void SaveGroups(IEnumerable<MeetingGroup> groups) => JsonFiles.Write(Path.Combine(Root, "groups.json"), groups);
}

internal static class TextElements
{
    public static IEnumerable<string> AsElements(this System.Globalization.TextElementEnumerator e) { while(e.MoveNext()) yield return e.GetTextElement(); }
    public static string[] Elements(this string s) => System.Globalization.StringInfo.GetTextElementEnumerator(s).AsElements().ToArray();
}
