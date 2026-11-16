using Minutes.Core;
using NAudio.Wave;
using System.Globalization;

namespace Minutes.App;

public sealed class TranscriptionService(AppSettings settings)
{
    private static string Models=>Path.Combine(AppSettings.Support,"models");
    private static string Tool(string name)
    {
        var path=Path.Combine(AppContext.BaseDirectory,"tools",name+".exe");return File.Exists(path)?path:throw new IOException(name+" is missing from this installation");
    }
    private static double Seconds(string file){using var reader=new AudioFileReader(file);return reader.TotalTime.TotalSeconds;}
    public async Task TranscribeAsync(string folder,IProgress<string>? progress=null,CancellationToken cancel=default)
    {
        var meta=Workspace.ReadMeta(folder)??throw new IOException("Meeting metadata missing");if(meta.IsNote)return;
        if(!new ModelStore(Models).Present(ModelStore.All[1]))throw new IOException("Speech model missing; choose Download Speech Models in Settings");
        var scratch=Path.Combine(AppSettings.Support,"transcription",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(scratch);
        try
        {
            var perTrack=new List<IReadOnlyList<TranscriptLine>>();var names=new List<string>();var duration=0d;
            foreach(var (name,label) in new[]{("me","Me"),("others","Others")})
            {
                var source=new[]{".flac",".wav"}.Select(ext=>Path.Combine(folder,name+ext)).FirstOrDefault(File.Exists);if(source==null)continue;
                var audio=Path.Combine(scratch,name+Path.GetExtension(source));File.Copy(source,audio);var seconds=Seconds(audio);duration=Math.Max(duration,seconds);names.Add(label);
                if(seconds<1){perTrack.Add([]);continue;}
                progress?.Report("Transcribing "+label);
                IReadOnlyList<SpeakerSegment> segments=[];
                if(settings.SeparateSpeakers&&(name=="others"||Modes.SeparatesMic(meta))&&ModelStore.All.Where(m=>!m.Transcription).All(m=>new ModelStore(Models).Present(m)))
                {
                    progress?.Report("Separating speakers · "+label);
                    var wav=audio;if(Path.GetExtension(audio)!=".wav"){wav=Path.Combine(scratch,name+".wav");using var read=new AudioFileReader(audio);WaveFileWriter.CreateWaveFile16(wav,read);}
                    var threads=Math.Min(4,Math.Max(1,Environment.ProcessorCount/2));
                    var args=new[]{"--clustering.cluster-threshold=0.65",$"--segmentation.num-threads={threads}",$"--embedding.num-threads={threads}","--segmentation.pyannote-model="+Path.Combine(Models,ModelStore.All[2].File),"--embedding.model="+Path.Combine(Models,ModelStore.All[3].File),wav};
                    var diarizer=Path.Combine(AppContext.BaseDirectory,"tools","sherpa-onnx-offline-speaker-diarization.exe");
                    if(File.Exists(diarizer))
                    {
                        var result=await ToolProcess.RunAsync(diarizer,args,"",scratch,TimeSpan.FromHours(3),cancel);
                        if(result.Status==0)segments=name=="me"?Diarizer.Absorb(Diarizer.Parse(result.Output),60,.03):Diarizer.Absorb(Diarizer.Parse(result.Output));
                    }
                }
                var split=segments.Select(s=>s.Speaker).Distinct().Count()>1;
                var output=Path.Combine(scratch,name);
                var argsWhisper=new List<string>{"-m",Path.Combine(Models,ModelStore.All[1].File),"-f",audio,"-l",settings.SpeechLanguage,"-ml","1","-mc","-1","-ojf","-of",output,"-np","-pp","--suppress-nst"};
                if(File.Exists(Path.Combine(Models,ModelStore.All[0].File)))argsWhisper.AddRange(["--vad","-vm",Path.Combine(Models,ModelStore.All[0].File)]);
                var whisper=await ToolProcess.RunAsync(Tool("whisper-cli"),argsWhisper,"",scratch,TimeSpan.FromHours(6),cancel);
                if(whisper.Status!=0)throw new IOException("whisper-cli: "+whisper.ErrorTail);
                var lines=Transcripts.ParseWhisper(await File.ReadAllBytesAsync(output+".json",cancel),split?t=>Diarizer.SpeakerAt(t,segments):null);
                if(split)lines=lines.Select(l=>l with{Voice=l.Voice??Diarizer.SpeakerAt(l.Start,segments,double.PositiveInfinity)}).ToArray();
                perTrack.Add(TranscriptCleaner.Clean(lines).Lines);
            }
            if(names.IndexOf("Me") is var me&&me>=0&&names.IndexOf("Others") is var others&&others>=0)perTrack[me]=TranscriptCleaner.Dedupe(perTrack[me],perTrack[others]).Kept;
            var heard=perTrack.SelectMany((lines,track)=>lines.Select(line=>(Track:track,Line:line))).OrderBy(x=>x.Line.Start).ToArray();
            var labels=Transcripts.Labels(heard.Select(h=>(h.Track,h.Line.Voice)).ToArray(),names);
            var rendered=Transcripts.Render(heard.Select((h,i)=>new NamedLine(h.Line.Start,labels[i],h.Line.Text)).ToArray(),meta.Title,meta.StartedAt,duration);
            JsonFiles.AtomicWrite(Path.Combine(folder,"transcript.md"),rendered);meta.TranscriptError=null;Workspace.WriteMeta(folder,meta);
        }
        catch(Exception e)when(e is not OperationCanceledException){meta.TranscriptError=e.Message;Workspace.WriteMeta(folder,meta);throw;}
        finally{Directory.Delete(scratch,true);}
    }
}
