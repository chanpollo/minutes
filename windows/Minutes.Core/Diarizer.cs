using System.Globalization;

namespace Minutes.Core;

public record SpeakerSegment(double Start, double End, int Speaker);
public static class Diarizer
{
    public const double Threshold = .65, AbsorbSeconds = 20, AbsorbShare = .05, RoomAbsorbSeconds = 60, RoomAbsorbShare = .03;
    public static IReadOnlyList<SpeakerSegment> Parse(string output)
    {
        var result = new List<SpeakerSegment>();
        foreach (var line in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var p = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (p.Length == 4 && p[1] == "--" && p[3].StartsWith("speaker_", StringComparison.Ordinal) &&
                double.TryParse(p[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var start) &&
                double.TryParse(p[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var end) && end > start && int.TryParse(p[3][8..], out var voice)) result.Add(new(start, end, voice));
        }
        return result;
    }
    public static IReadOnlyList<SpeakerSegment> Absorb(IEnumerable<SpeakerSegment> source, double maxSeconds = AbsorbSeconds, double share = AbsorbShare, int minVoices = 2)
    {
        var segments = source.ToArray();
        while (true)
        {
            var totals = segments.GroupBy(s => s.Speaker).Select(g => (Speaker: g.Key, Total: g.Sum(s => s.End - s.Start))).ToArray();
            if (totals.Length <= minVoices) break;
            var cutoff = Math.Min(maxSeconds, share * totals.Sum(t => t.Total));
            var small = totals.Where(t => t.Total < cutoff).OrderBy(t => t.Total).Select(t => (int?)t.Speaker).FirstOrDefault();
            if (small == null) break;
            var hosts = segments.Where(s => s.Speaker != small).ToArray();
            segments = segments.Select(s => s.Speaker != small ? s : s with { Speaker = hosts.OrderBy(h => Math.Max(0, Math.Max(s.Start, h.Start) - Math.Min(s.End, h.End))).ThenByDescending(h => h.End - h.Start).First().Speaker }).ToArray();
        }
        return segments;
    }
    public static int? SpeakerAt(double time, IReadOnlyList<SpeakerSegment> segments, double reach = 1)
    {
        var cover = segments.Where(s => s.Start <= time && time <= s.End).OrderByDescending(s => s.End - s.Start).FirstOrDefault();
        if (cover != null) return cover.Speaker;
        double Distance(SpeakerSegment s) => time < s.Start ? s.Start - time : time - s.End;
        var nearest = segments.OrderBy(Distance).FirstOrDefault();
        return nearest != null && Distance(nearest) <= reach ? nearest.Speaker : null;
    }
}
