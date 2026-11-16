using Minutes.Core;
using NAudio.Wave;
using NAudio.MediaFoundation;
using Windows.Media.SpeechSynthesis;

namespace Minutes.App;

internal sealed class BriefingService(AppSettings settings, SummaryService summaries)
{
    public async Task<string> MakeAsync(string folder, bool reuse = true, CancellationToken cancel = default)
    {
        var meta = Workspace.ReadMeta(folder) ?? throw new IOException("Meeting is missing"); var summary = await File.ReadAllTextAsync(Path.Combine(folder, "summary.md"), cancel); var hash = Briefing.Hash(summary);
        if (reuse && meta.Briefing is { } previous && previous.TryGetProperty("summaryHash", out var saved) && saved.GetString() == hash && File.Exists(Path.Combine(folder, "briefing.m4a"))) return Path.Combine(folder, "briefing.m4a");
        var language = Briefing.Language(summary); var local = settings.SummaryProvider == "off" || meta.Confidential == true && meta.SentAnyway != true; var body = Briefing.SummaryBody(summary);
        var script = local ? Briefing.LocalScript(meta, body, language) : Briefing.Clean(await summaries.RunAsync(new(settings.SummaryProvider, settings.SummaryModel), SummaryPrompts.Resource("briefing-" + language), Briefing.Input(meta, body), cancel));
        if (script.Trim().Length == 0) throw new IOException("The briefing script is empty");
        var work = Path.Combine(AppSettings.Support, "briefing", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(work);
        try
        {
            using var synth = new SpeechSynthesizer(); var desired = language == "thai" ? settings.BriefingVoiceThai : settings.BriefingVoiceEnglish;
            var voice = SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Id == desired) ?? SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Language.StartsWith(language == "thai" ? "th" : "en", StringComparison.OrdinalIgnoreCase));
            if (voice == null) throw new IOException("Install a " + (language == "thai" ? "Thai" : "English") + " speech voice in Windows Settings"); synth.Voice = voice; synth.Options.SpeakingRate = new[] { .8, .9, 1, 1.1, 1.2 }[Math.Clamp(settings.BriefingRate, 0, 4)];
            var wav = Path.Combine(work, "briefing.wav"); WaveFileWriter? writer = null; var marks = new List<double>(); double duration = 0;
            try
            {
                foreach (var sentence in Briefing.Parse(script).SelectMany(p => p))
                {
                    cancel.ThrowIfCancellationRequested(); using var audio = await synth.SynthesizeTextToStreamAsync(sentence); using var input = audio.AsStreamForRead(); using var reader = new WaveFileReader(input);
                    writer ??= new(wav, reader.WaveFormat); if (!reader.WaveFormat.Equals(writer.WaveFormat)) throw new IOException("Speech voice changed audio format");
                    marks.Add((double)writer.Length / writer.WaveFormat.AverageBytesPerSecond); var buffer = new byte[16384]; int n; while ((n = reader.Read(buffer, 0, buffer.Length)) > 0) writer.Write(buffer, 0, n);
                }
                duration = writer == null ? 0 : (double)writer.Length / writer.WaveFormat.AverageBytesPerSecond;
            }
            finally { writer?.Dispose(); }
            var m4a = Path.Combine(work, "briefing.m4a"); await Task.Run(() => { MediaFoundationApi.Startup(); using var reader = new WaveFileReader(wav); MediaFoundationEncoder.EncodeToAac(reader, m4a, 128000); }, cancel);
            JsonFiles.AtomicWrite(Path.Combine(folder, "briefing.md"), script + "\n"); File.Move(m4a, Path.Combine(folder, "briefing.m4a"), true);
            meta = Workspace.ReadMeta(folder) ?? meta; meta.Briefing = System.Text.Json.JsonSerializer.SerializeToElement(new { summaryAt = meta.SummarizedAt, summaryHash = hash, scriptAt = DateTimeOffset.Now, madeAt = DateTimeOffset.Now, voice = voice.DisplayName, language = language == "thai" ? "th" : "en", duration, marks, local = local ? (bool?)true : null }, JsonFiles.Options); Workspace.WriteMeta(folder, meta);
            return Path.Combine(folder, "briefing.m4a");
        }
        finally { Directory.Delete(work, true); }
    }
}
