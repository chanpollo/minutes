namespace Minutes.Core;

public record FrameSample(double Time, byte[] Cells);
public record FrameMoment(double Time, double Shot, double From, double To, double Length);
public static class FrameSelection
{
    public const int Columns = 64, Rows = 36, Limit = 40, BusyWindow = 20;
    public const double Step = 1, StillFor = 3, CellChange = 12, StillChanged = .01, DistinctChanged = .04, BusyShare = .3;
    public static IReadOnlyList<FrameMoment> Moments(IReadOnlyList<FrameSample> samples)
    {
        const int count = Columns * Rows;
        if (samples.Any(s => s.Cells.Length != count)) throw new ArgumentException("Frame signatures must be 64 by 36");
        if (samples.Count < 2) return [];
        var steps = samples.Zip(samples.Skip(1), (a, b) => Enumerable.Range(0, count).Where(i => Math.Abs(a.Cells[i] - b.Cells[i]) > CellChange).ToArray()).ToArray();
        bool[] Busy(int start)
        {
            var span = Enumerable.Range(start, Math.Max(0, Math.Min(steps.Length, start + BusyWindow) - start)).Where(i => steps[i].Length < BusyShare * count).ToArray();
            var counts = new int[count]; foreach (var i in span) foreach (var cell in steps[i]) counts[cell]++;
            var needed = Math.Max(2, (span.Length + 1) / 2); return counts.Select(n => n >= needed).ToArray();
        }
        double Changed(byte[] a, byte[] b, bool[] mask)
        { var watched = Enumerable.Range(0, count).Where(i => !mask[i]).ToArray(); return watched.Length == 0 ? 1 : (double)watched.Count(i => Math.Abs(a[i] - b[i]) > CellChange) / watched.Length; }
        bool Blank(byte[] cells, bool[] mask)
        { var values = Enumerable.Range(0, count).Where(i => !mask[i]).Select(i => (double)cells[i]).ToArray(); if (values.Length == 0) return true; var mean = values.Average(); return values.Average(n => (n - mean) * (n - mean)) < 4; }
        var kept = new List<(FrameMoment Moment, byte[] Cells, bool[] Mask)>();
        for (var start = 0; start < samples.Count;)
        {
            var mask = Busy(start); var end = start;
            if (mask.Count(x => x) <= BusyShare * count) while (end + 1 < samples.Count && Changed(samples[end + 1].Cells, samples[end].Cells, mask) <= StillChanged && Changed(samples[end + 1].Cells, samples[start].Cells, mask) <= StillChanged) end++;
            var first = samples[start]; var last = samples[end]; var length = last.Time - first.Time + Step; start = end + 1;
            if (length < StillFor || Blank(first.Cells, mask)) continue;
            var moment = new FrameMoment(first.Time, first.Time + Math.Min(1, (last.Time - first.Time) / 2), first.Time, last.Time, length);
            var same = kept.FindLastIndex(e => Changed(e.Cells, first.Cells, e.Mask.Zip(mask, (a, b) => a || b).ToArray()) < DistinctChanged);
            if (same >= 0)
            {
                if (same == kept.Count - 1) { var old = kept[same]; kept[same] = (old.Moment with { Shot = moment.Shot, From = moment.From, To = moment.To, Length = old.Moment.Length + length }, first.Cells, old.Mask); }
                continue;
            }
            kept.Add((moment, first.Cells, mask));
        }
        var moments = kept.Select(k => k.Moment); return moments.Count() > Limit ? moments.OrderByDescending(m => m.Length).Take(Limit).OrderBy(m => m.Time).ToArray() : moments.ToArray();
    }
}
