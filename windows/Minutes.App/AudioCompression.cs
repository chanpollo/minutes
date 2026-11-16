using Minutes.Core;
using NAudio.Wave;

namespace Minutes.App;
internal static class AudioCompression
{
    public static async Task CompressAsync(string folder, CancellationToken cancel = default)
    {
        var flac = Path.Combine(AppContext.BaseDirectory, "tools", "flac.exe"); if (!File.Exists(flac)) return;
        foreach (var name in new[] { "me", "others" })
        {
            var wav = Path.Combine(folder, name + ".wav"); if (!File.Exists(wav)) continue;
            var work = Path.Combine(AppSettings.Support, "compression", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(work);
            try
            {
                var encoded = Path.Combine(work, name + ".flac"); var verified = Path.Combine(work, name + ".wav");
                var result = await ToolProcess.RunAsync(flac, ["--silent", "--verify", "--force", "--output-name=" + encoded, wav], "", work, TimeSpan.FromMinutes(20), cancel);
                if (result.Status != 0) continue;
                result = await ToolProcess.RunAsync(flac, ["--decode", "--silent", "--force", "--output-name=" + verified, encoded], "", work, TimeSpan.FromMinutes(20), cancel);
                if (result.Status != 0 || !SameSamples(wav, verified) || new FileInfo(encoded).Length >= new FileInfo(wav).Length) continue;
                File.Move(encoded, Path.Combine(folder, name + ".flac"), true); File.Delete(wav);
            }
            finally { Directory.Delete(work, true); }
        }
    }
    private static bool SameSamples(string a, string b)
    {
        using var first = new WaveFileReader(a); using var second = new WaveFileReader(b);
        if (first.Length != second.Length || !first.WaveFormat.Equals(second.WaveFormat)) return false;
        var x = new byte[65536]; var y = new byte[65536]; int n;
        while ((n = first.Read(x, 0, x.Length)) > 0) { var read = 0; while (read < n) { var count = second.Read(y, read, n - read); if (count == 0) return false; read += count; } if (!x.AsSpan(0, n).SequenceEqual(y.AsSpan(0, n))) return false; }
        return second.Read(y, 0, 1) == 0;
    }
}
