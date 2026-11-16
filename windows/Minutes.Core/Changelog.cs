using System.Globalization;
using System.Text.RegularExpressions;

namespace Minutes.Core;

public record Release(string Version, int? Build = null, string? Date = null)
{
    public List<string> Items { get; } = [];
    public string? DateText => Date == null ? null : Changelog.DateText(Date);
}
public static class Changelog
{
    public static IReadOnlyList<Release> Parse(string text)
    {
        var releases = new List<Release>();
        foreach (var raw in Regex.Split(text, @"\r\n|\r|\n"))
        {
            var line = raw.Trim();
            if (line.StartsWith("## ", StringComparison.Ordinal)) releases.Add(Heading(line[3..]));
            else if (releases.Count == 0 || line.Length == 0 || line.StartsWith('#')) continue;
            else if (line.StartsWith("- ", StringComparison.Ordinal) || line.StartsWith("* ", StringComparison.Ordinal)) releases[^1].Items.Add(line[2..].Trim());
            else if (releases[^1].Items.Count > 0) releases[^1].Items[^1] += " " + line;
        }
        return releases;
    }
    public static Release Heading(string text)
    {
        string? date = null; int? build = null;
        var dash = Regex.Match(text, @"\s+[—–-]+\s+");
        if (dash.Success) { date = text[(dash.Index + dash.Length)..].Trim(); text = text[..dash.Index]; }
        var tail = Regex.Match(text, @"\s*\((?:build\s+)?(\d+)\)\s*$");
        if (tail.Success) { build = int.Parse(tail.Groups[1].Value, CultureInfo.InvariantCulture); text = text[..tail.Index]; }
        return new(text.Trim(), build, date);
    }
    public static string DateText(string written) => DateTime.TryParseExact(written, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d.ToString("d MMM yyyy", CultureInfo.InvariantCulture) : written;
}
