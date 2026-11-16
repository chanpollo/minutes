using System.Security.Cryptography;
using System.Text;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Minutes.App;

internal static class AudioPlaybackCache
{
    private static readonly SemaphoreSlim gate = new(1);
    public static async Task<string?> PrepareAsync(string folder)
    {
        var tracks = new[] { "me", "others" }.Select(name => new[] { ".flac", ".wav" }.Select(ext => Path.Combine(folder, name + ext)).FirstOrDefault(File.Exists)).Where(p => p != null).Select(p => p!).ToArray();
        if (tracks.Length < 2) return tracks.FirstOrDefault();
        var stamp = string.Join("\n", tracks.Select(p => p + "|" + new FileInfo(p).Length + "|" + File.GetLastWriteTimeUtc(p).Ticks));
        var root = Path.Combine(AppSettings.Support, "playback-cache"); Directory.CreateDirectory(root);
        var target = Path.Combine(root, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(stamp))) + ".wav");
        await gate.WaitAsync();
        try
        {
            if (File.Exists(target)) return target;
            await Task.Run(() =>
            {
                var part = target + ".partial";
                try
                {
                    using var me = new AudioFileReader(tracks[0]); using var others = new AudioFileReader(tracks[1]);
                    var mixer = new MixingSampleProvider(new ISampleProvider[] { me, others });
                    var volume = new VolumeSampleProvider(mixer) { Volume = .5f }; WaveFileWriter.CreateWaveFile16(part, volume); File.Move(part, target, true);
                }
                finally { if (File.Exists(part)) File.Delete(part); }
            });
            long retained = 0;
            foreach (var cached in new DirectoryInfo(root).GetFiles("*.wav").OrderByDescending(f => f.LastWriteTimeUtc))
            {
                retained += cached.Length; if (retained <= 1024L * 1024 * 1024 || cached.FullName == target) continue;
                try { cached.Delete(); } catch (IOException) { }
            }
            return target;
        }
        finally { gate.Release(); }
    }
}
