using System.Text.Json;

using System.Text.RegularExpressions;

namespace Minutes.Core;

public record SyncOptions(bool Text = true, bool Media = true);
public static class SyncPlan
{
    public static readonly string[] TextFiles = ["transcript.md", "summary.md", "notes.md", "comments.md", "briefing.md"];
    public static readonly string[] AudioNames = ["me", "others"];
    public static IReadOnlyList<string> Files(string folder, MeetingMeta meta, SyncOptions? options = null)
    {
        if (meta.Confidential == true) return [];
        options ??= new(); var names = new List<string>();
        bool Exists(string name) => File.Exists(Path.Combine(folder, name));
        if (options.Text)
        {
            names.AddRange(TextFiles.Where(Exists));
            foreach (var file in new[] { "summary.md", "notes.md" }.Where(Exists))
            {
                var text = File.ReadAllText(Path.Combine(folder, file));
                names.AddRange(Images(text).Where(p => p.StartsWith("frames/", StringComparison.Ordinal)).Where(Exists));
                if (file == "notes.md") names.AddRange(Attachments.Referenced(text).Where(Exists));
            }
        }
        if (options.Media)
        {
            if (Exists("meeting.mp4")) names.Add("meeting.mp4");
            else if (meta.VideoDeletedAt == null) foreach (var name in AudioNames)
                { if (Exists(name + ".flac")) names.Add(name + ".flac"); else if (Exists(name + ".wav")) names.Add(name + ".wav"); }
        }
        return names.Distinct(StringComparer.Ordinal).ToArray();
    }
    public static IEnumerable<string> Images(string text) => Regex.Matches(text, @"!\[[^\]\n]*\]\(((?:frames|attachments)/[^)\s]+)\)")
        .Select(m => m.Groups[1].Value).Where(p => !p.Contains("..", StringComparison.Ordinal) && !p.Contains('\\') && !p.Contains(':'));
    public static string Destination(string meetingFolder, string? group) => string.IsNullOrEmpty(group) ? Path.GetFileName(meetingFolder) : Workspace.CleanTitle(group) + "/" + Path.GetFileName(meetingFolder);
    public static string SafePath(string root, string relative)
    {
        if (Path.IsPathRooted(relative) || relative.Contains(':') || relative.Split('/', '\\').Any(p => p is ".." or "." or "")) throw new IOException("Unsafe relative path");
        var path = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
        if (!path.StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) throw new IOException("Path leaves sync root");
        return path;
    }
}

public sealed class FolderSync(Workspace workspace)
{
    private readonly SemaphoreSlim gate = new(1);
    public sealed class State
    {
        public string Base { get; set; } = "";
        public string Path { get; set; } = "";
        public Dictionary<string, Stamp> Files { get; set; } = [];
    }
    public record Stamp(long Size, DateTimeOffset Modified);
    public async Task CopyAsync(Meeting meeting, string syncFolder, SyncOptions? options = null, bool perGroup = true, CancellationToken cancel = default)
    {
        await gate.WaitAsync(cancel);
        try
        {
            var current = workspace.Find(meeting.Meta.Id) ?? throw new IOException("Meeting is gone");
            var meta = current.Meta;
            var state = meta.Sync?.Deserialize<State>(JsonFiles.Options);
            if (meta.Confidential == true)
            {
                if (state == null) return;
                if (!Directory.Exists(state.Base)) throw new IOException("Previous sync folder is unavailable");
                var copy = SyncPlan.SafePath(Path.Combine(state.Base, "Minutes"), state.Path);
                if (Directory.Exists(copy)) Directory.Delete(copy, true);
                workspace.Update(current.Folder, m => m.Sync = null); return;
            }
            if (!Directory.Exists(syncFolder)) throw new IOException("Sync folder is unavailable");
            var group = perGroup ? workspace.Groups().FirstOrDefault(g => g.Id == meta.GroupID)?.Name : null;
            var root = Path.Combine(syncFolder, "Minutes"); var wanted = SyncPlan.Destination(current.Folder, group);
            if (state == null || state.Base != syncFolder) state = new() { Base = syncFolder, Path = wanted };
            if (state.Path != wanted)
            {
                var from = SyncPlan.SafePath(root, state.Path); var to = SyncPlan.SafePath(root, wanted);
                if (Directory.Exists(from) && !Directory.Exists(to)) { Directory.CreateDirectory(Path.GetDirectoryName(to)!); Directory.Move(from, to); }
                else state.Files.Clear();
                state.Path = wanted;
            }
            var destination = SyncPlan.SafePath(root, wanted); Directory.CreateDirectory(destination);
            workspace.Update(current.Folder, m => m.Sync = JsonSerializer.SerializeToElement(state, JsonFiles.Options));
            bool WithdrawIfConfidential()
            {
                var latest = workspace.Find(meta.Id);
                if (latest?.Meta.Confidential != true) return false;
                if (Directory.Exists(destination)) Directory.Delete(destination, true);
                workspace.Update(latest.Folder, m => m.Sync = null); return true;
            }
            foreach (var name in SyncPlan.Files(current.Folder, meta, options))
            {
                cancel.ThrowIfCancellationRequested();
                if (WithdrawIfConfidential()) return;
                var source = SyncPlan.SafePath(current.Folder, name); var target = SyncPlan.SafePath(destination, name);
                var f = new FileInfo(source); var stamp = new Stamp(f.Length, DateTimeOffset.FromUnixTimeSeconds(new DateTimeOffset(f.LastWriteTimeUtc).ToUnixTimeSeconds()));
                if (state.Files.TryGetValue(name, out var old) && old == stamp && File.Exists(target)) continue;
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                var part = Path.Combine(Path.GetDirectoryName(target)!, "." + Path.GetFileName(target) + ".minutes-partial");
                try { File.Copy(source, part, true); File.Move(part, target, true); }
                finally { if (File.Exists(part)) File.Delete(part); }
                state.Files[name] = stamp;
                if (WithdrawIfConfidential()) return;
            }
            foreach (var name in SyncPlan.AudioNames.Select(n => n + ".wav").Where(n => state.Files.ContainsKey(n) && state.Files.ContainsKey(n.Replace(".wav", ".flac")) && !File.Exists(Path.Combine(current.Folder, n))).ToArray())
            { File.Delete(SyncPlan.SafePath(destination, name)); state.Files.Remove(name); }
            if (WithdrawIfConfidential()) return;
            workspace.Update(current.Folder, m => m.Sync = System.Text.Json.JsonSerializer.SerializeToElement(state, JsonFiles.Options));
        }
        finally { gate.Release(); }
    }
}
