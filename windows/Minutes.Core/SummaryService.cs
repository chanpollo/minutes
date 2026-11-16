using System.Diagnostics;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Minutes.Core;

public sealed class SummaryService : IDisposable
{
    private static readonly string[] OffFeatures = ["shell_tool","unified_exec","apps","plugins","memories","multi_agent","image_generation","browser_use","browser_use_external","computer_use","in_app_browser","hooks","goals","view_image","tool_suggest","skill_search","sleep_tool"];
    private readonly string workDir;
    private readonly Func<string,string?> tool;
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(20) };
    private Process? ollama;
    public SummaryService(string support, Func<string,string?>? tool = null) { workDir=Path.Combine(support,"summary-cwd");this.tool=tool??(name=>ToolProcess.Find(name)); }
    public async Task<string> RunAsync(SummaryModel model,string system,string input,CancellationToken cancel=default)
    {
        if(model.Provider=="ollama")return await OllamaAsync(model,system,input,cancel);
        var exe=tool(model.Provider)??throw new IOException($"{model.Provider} CLI not found");
        if(model.Provider=="claude")
        {
            var result=await ToolProcess.RunAsync(exe,["-p","--model",model.Name,"--tools","","--strict-mcp-config","--setting-sources","","--no-session-persistence","--output-format","text","--system-prompt",system],input,workDir,model.Timeout,cancel);
            if(result.Status!=0)throw new IOException($"claude exited with {result.Status}: {result.ErrorTail}");return result.Output;
        }
        if(model.Provider=="agy")
        {
            var prompt="A program calls you; there is no one to chat with. Do not use any tool, file or web search: everything you need is below. Follow these instructions:\n\n"+system+"\n\nThe input:\n\n"+input;
            var line=JsonSerializer.Serialize(new{ @event="user",message=new{role="user",content=prompt}})+"\n";
            var args=new List<string>{"--input-format","stream-json","--output-format","stream-json","--disable-slash-commands","--sandbox","--print-timeout",$"{(int)model.Timeout.TotalSeconds}s"};
            if(model.Name.Length>0)args.AddRange(["--model",model.Name]);args.Add("-p=");
            var result=await ToolProcess.RunAsync(exe,args,line,workDir,model.Timeout+TimeSpan.FromSeconds(30),cancel);
            foreach(var row in result.Output.Split('\n').Reverse())
            {
                JsonDocument doc;try{doc=JsonDocument.Parse(row);}catch(JsonException){continue;}
                using(doc)if(doc.RootElement.TryGetProperty("event",out var type)&&type.GetString()=="result"&&doc.RootElement.TryGetProperty("result",out var outcome))
                {
                    if(outcome.GetProperty("status").GetString()=="SUCCESS"&&outcome.TryGetProperty("response",out var response))return response.GetString()??"";
                    throw new IOException("agy: "+outcome.ToString());
                }
            }
            throw new IOException($"agy exited with {result.Status}: {result.ErrorTail}");
        }
        if(model.Provider!="codex")throw new ArgumentException("Unknown provider");
        var scratch=Path.Combine(Path.GetTempPath(),"minutes-codex-"+Guid.NewGuid());Directory.CreateDirectory(scratch);
        try
        {
            var reply=Path.Combine(scratch,"reply.md");var off=OffFeatures.ToList();
            var instructions="A program calls you; there is no one to chat with. Do not run commands or use any tool. These instructions replace any others you were given about language, tone, format or the user (such as AGENTS.md).\n\n"+system;
            for(var i=0;i<OffFeatures.Length;i++)
            {
                var args=new List<string>{"exec","--ignore-user-config","--ignore-rules","--skip-git-repo-check","--ephemeral","--sandbox","read-only","--color","never","--cd",workDir,"-c","web_search=\"disabled\"","-c","developer_instructions="+JsonSerializer.Serialize(instructions,JsonFiles.Options),"--output-last-message",reply};
                foreach(var feature in off)args.AddRange(["--disable",feature]);if(model.Name.Length>0)args.AddRange(["--model",model.Name]);args.Add("Do what your developer instructions say with the text in the stdin block.");
                var result=await ToolProcess.RunAsync(exe,args,input,workDir,model.Timeout,cancel);
                if(result.Status==0)return File.Exists(reply)?await File.ReadAllTextAsync(reply,cancel):result.Output;
                var unknown=Regex.Match(result.ErrorTail,@"Unknown feature flag: (\S+)");
                if(unknown.Success&&off.Remove(unknown.Groups[1].Value))continue;
                throw new IOException($"codex exited with {result.Status}: {result.ErrorTail}");
            }
            throw new IOException("codex refused its feature flags");
        }
        finally{Directory.Delete(scratch,true);}
    }
    private async Task<string> OllamaAsync(SummaryModel model,string system,string input,CancellationToken cancel)
    {
        if(model.Name.Length==0)throw new IOException("No Ollama model chosen");
        const string endpoint="http://127.0.0.1:21434";
        async Task<bool> Reachable(){try{using var t=CancellationTokenSource.CreateLinkedTokenSource(cancel);t.CancelAfter(1000);using var r=await http.GetAsync(endpoint+"/api/version",t.Token);return r.IsSuccessStatusCode;}catch(HttpRequestException){return false;}catch(OperationCanceledException)when(!cancel.IsCancellationRequested){return false;}}
        if(!await Reachable())
        {
            if(ollama==null||ollama.HasExited)
            {
                var start=new ProcessStartInfo(tool("ollama")??throw new IOException("Ollama not found"),"serve"){UseShellExecute=false,CreateNoWindow=true};start.Environment["OLLAMA_HOST"]="127.0.0.1:21434";ollama=Process.Start(start);
            }
            var ready=false;for(var i=0;i<40;i++){if(await Reachable()){ready=true;break;}await Task.Delay(500,cancel);}if(!ready)throw new IOException("Ollama did not start on port 21434");
        }
        var limit=8192;
        using(var show=await http.PostAsJsonAsync(endpoint+"/api/show",new{model=model.Name},cancel))
        {
            show.EnsureSuccessStatusCode();using var json=JsonDocument.Parse(await show.Content.ReadAsStringAsync(cancel));
            if(json.RootElement.TryGetProperty("model_info",out var info))foreach(var property in info.EnumerateObject())if(property.Name.EndsWith(".context_length",StringComparison.Ordinal))limit=Math.Min(property.Value.GetInt32(),65536);
        }
        var needed=(system.EnumerateRunes().Count()+input.EnumerateRunes().Count())/2+4096;
        var window=Math.Min(limit,Math.Max(8192,(needed+4095)/4096*4096));
        using var response=await http.PostAsJsonAsync(endpoint+"/api/chat",new{model=model.Name,stream=false,keep_alive="2m",options=new{num_ctx=window,temperature=.2},messages=new[]{new{role="system",content=system},new{role="user",content=input}}},cancel);
        response.EnsureSuccessStatusCode();using var result=JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancel));
        if(result.RootElement.TryGetProperty("prompt_eval_count",out var read)&&read.GetInt32()>=window-16)throw new IOException("The transcript is longer than this model can read at once");
        return Regex.Replace(result.RootElement.GetProperty("message").GetProperty("content").GetString()??"",@"<think>[\s\S]*?</think>","");
    }
    public async Task<string> SummarizeAsync(string folder,SummaryModel model,string language="thai",bool providerOff=false,bool force=false,CancellationToken cancel=default)
    {
        if(providerOff)throw new InvalidOperationException("Summaries are off. Choose a provider under Summary in Settings.");
        var meta=Workspace.ReadMeta(folder)??throw new IOException("Meeting metadata missing");
        if(meta.IsNote)throw new InvalidOperationException("Record this note before summarising it");
        if(meta.Confidential==true&&!force)throw new InvalidOperationException("Marked confidential, so it was not sent for summary.");
        var transcript=await File.ReadAllTextAsync(Path.Combine(folder,"transcript.md"),cancel);
        var frames=File.Exists(Path.Combine(folder,"frames","frames.json"))?JsonFiles.Read<VideoFrame[]>(Path.Combine(folder,"frames","frames.json"))??[]:[];
        var pictures=SummaryPrompts.Pictures(frames);
        var input=$"Meeting: {meta.Title}, {Transcripts.Stamp(meta.StartedAt)}\n"+(meta.Attendees?.Length>0?"Invited: "+string.Join(", ",meta.Attendees)+"\n":"")+"\n"+transcript+(pictures.Length>0?"\n\n"+pictures:"");
        var raw=await RunAsync(model,SummaryPrompts.Prompt(language,pictures.Length>0,meta.RecordMode=="voice"),input,cancel);
        var text=SummaryPrompts.KeepKnownPictures(raw,frames.Select(f=>f.File).ToHashSet(StringComparer.Ordinal)).Trim();if(text.Length==0)throw new IOException(model.Label+" returned an empty summary");
        var current=Workspace.ReadMeta(folder)??meta;
        JsonFiles.AtomicWrite(Path.Combine(folder,"summary.md"),$"# {current.Title}\n\n{Transcripts.Stamp(meta.StartedAt)} · Summarised by {model.Label}\n\n{text}\n");
        current.SummaryModel=model.RawValue;current.SummarizedAt=DateTimeOffset.Now;current.SentAnyway=force&&current.Confidential==true?true:null;Workspace.WriteMeta(folder,current);
        return Path.Combine(folder,"summary.md");
    }
    public void Dispose(){if(ollama!=null){try{if(!ollama.HasExited)ollama.Kill(true);}catch(InvalidOperationException){}ollama.Dispose();}http.Dispose();}
}
