using System.Security.Cryptography;

namespace Minutes.Core;

public record SpeechModel(string File, string Source, long Size, string Sha256, bool Transcription, string? ArchiveSha256 = null, string? ArchiveMember = null);
public sealed class ModelStore(string modelsDir)
{
    public static readonly SpeechModel[] All =
    [
        new("ggml-silero-v5.1.2.bin","https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin",885098,"29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",true),
        new("ggml-large-v3-turbo-q5_0.bin","https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",574041195,"394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",true),
        new("sherpa-onnx-pyannote-segmentation-3-0/model.onnx","https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",5992913,"220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",false,"24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488","sherpa-onnx-pyannote-segmentation-3-0/model.onnx"),
        new("3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx","https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",28281164,"aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2",false)
    ];
    public bool Present(SpeechModel model) => System.IO.File.Exists(Path.Combine(modelsDir, model.File)) && new FileInfo(Path.Combine(modelsDir, model.File)).Length == model.Size;
    public static async Task VerifyAsync(string file, string expected, CancellationToken cancel = default)
    {
        await using var stream = System.IO.File.OpenRead(file); var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancel)).ToLowerInvariant();
        if (hash != expected) throw new InvalidDataException(Path.GetFileName(file) + " is damaged (checksum mismatch)");
    }
    public async Task DownloadAsync(bool speakers = true, IProgress<string>? progress = null, CancellationToken cancel = default)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromHours(2) }; Directory.CreateDirectory(modelsDir);
        foreach (var model in All.Where(m => speakers || m.Transcription).Where(m => !Present(m)))
        {
            var part = Path.Combine(modelsDir, Path.GetFileName(new Uri(model.Source).AbsolutePath) + ".part"); var scratch = Path.Combine(modelsDir, ".extract-" + Guid.NewGuid());
            var installed=false;
            try
            {
                progress?.Report("Downloading " + model.File);
                await ResumableDownload.FetchAsync(client,model.Source,part,new Progress<long>(done=>progress?.Report($"Downloading {Path.GetFileName(model.File)} · {done/1000000} MB")),cancel);
                var install = part;
                if (model.ArchiveSha256 != null)
                {
                    await VerifyAsync(part, model.ArchiveSha256, cancel); Directory.CreateDirectory(scratch);
                    var result = await ToolProcess.RunAsync("tar", ["-xjf", part, "-C", scratch, model.ArchiveMember!], "", modelsDir, TimeSpan.FromMinutes(2), cancel);
                    if (result.Status != 0) throw new IOException("Model archive could not be unpacked: " + result.ErrorTail);
                    install = Path.Combine(scratch, model.ArchiveMember!);
                }
                await VerifyAsync(install, model.Sha256, cancel);
                if (new FileInfo(install).Length != model.Size) throw new InvalidDataException("Model size mismatch");
                var target = Path.Combine(modelsDir, model.File); Directory.CreateDirectory(Path.GetDirectoryName(target)!); System.IO.File.Move(install, target, true);installed=true;
            }
            catch(InvalidDataException){if(System.IO.File.Exists(part))System.IO.File.Delete(part);throw;}
            finally { if(installed&&System.IO.File.Exists(part)) System.IO.File.Delete(part); if (Directory.Exists(scratch)) Directory.Delete(scratch, true); }
        }
    }
}
