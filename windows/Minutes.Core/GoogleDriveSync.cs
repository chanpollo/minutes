using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace Minutes.Core;

public sealed class GoogleDriveSync(Workspace workspace,GoogleOAuth auth,HttpClient http)
{
    private const string Files="https://www.googleapis.com/drive/v3/files";
    private readonly SemaphoreSlim gate=new(1);
    public sealed class State
    {
        public string? FolderID { get; set; }
        public string? FolderName { get; set; }
        public string? GroupID { get; set; }
        public string? FramesFolderID { get; set; }
        public string? AttachmentsFolderID { get; set; }
        public Dictionary<string,DriveFile> Files { get; set; }=[];
    }
    public record DriveFile(string Id,long Size,DateTimeOffset Modified);
    public async Task CopyAsync(Meeting meeting,SyncOptions? options=null,bool perGroup=true,CancellationToken cancel=default)
    {
        await gate.WaitAsync(cancel);
        try
        {
            var current=workspace.Find(meeting.Meta.Id)??throw new IOException("Meeting is gone");var meta=current.Meta;
            var state=meta.Drive?.Deserialize<State>(JsonFiles.Options)??new();
            if(meta.Confidential==true){await WithdrawAsync(current,cancel);return;}
            var root=await FolderAsync("Minutes",null,cancel);
            var group=perGroup?workspace.Groups().FirstOrDefault(g=>g.Id==meta.GroupID):null;
            var parent=group==null?root:await FolderAsync(group.Name,root,cancel);
            var name=Path.GetFileName(current.Folder);
            if(state.FolderID==null||!await LiveAsync(state.FolderID,cancel))state=new(){FolderID=await CreateFolderAsync(name,parent,cancel),FolderName=name,GroupID=group?.Id};
            else if(state.FolderName!=name||state.GroupID!=group?.Id)
            {
                using var existing=await SendAsync(()=>new(HttpMethod.Get,Files+"/"+state.FolderID+"?fields=parents"),cancel);
                using var json=JsonDocument.Parse(await existing.Content.ReadAsStringAsync(cancel));
                var parents=json.RootElement.TryGetProperty("parents",out var p)?string.Join(",",p.EnumerateArray().Select(e=>e.GetString())):"";
                var url=Files+"/"+state.FolderID+"?addParents="+Uri.EscapeDataString(parent)+(parents.Length>0?"&removeParents="+Uri.EscapeDataString(parents):"");
                using var changed=await SendAsync(()=>new(HttpMethod.Patch,url){Content=JsonContent.Create(new{name})},cancel);
                state.FolderName=name;state.GroupID=group?.Id;
            }
            void Save()=>workspace.Update(current.Folder,m=>m.Drive=JsonSerializer.SerializeToElement(state,JsonFiles.Options));
            Save();
            foreach(var relative in SyncPlan.Files(current.Folder,meta,options))
            {
                cancel.ThrowIfCancellationRequested();
                if(workspace.Find(meta.Id)?.Meta.Confidential==true){await WithdrawAsync(workspace.Find(meta.Id)!,cancel);return;}
                var file=SyncPlan.SafePath(current.Folder,relative);var info=new FileInfo(file);var modified=DateTimeOffset.FromUnixTimeSeconds(new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeSeconds());
                state.Files.TryGetValue(relative,out var old);
                if(old!=null&&old.Size==info.Length&&old.Modified==modified)continue;
                var folderID=state.FolderID!;
                if(relative.StartsWith("frames/",StringComparison.Ordinal))folderID=state.FramesFolderID??=await FolderAsync("frames",state.FolderID,cancel);
                else if(relative.StartsWith("attachments/",StringComparison.Ordinal))folderID=state.AttachmentsFolderID??=await FolderAsync("attachments",state.FolderID,cancel);
                var id=await UploadAsync(file,folderID,old?.Id,cancel);state.Files[relative]=new(id,info.Length,modified);Save();
            }
            if(workspace.Find(meta.Id)?.Meta.Confidential==true){await WithdrawAsync(workspace.Find(meta.Id)!,cancel);return;}
            foreach(var stale in SyncPlan.AudioNames.Select(n=>n+".wav").Where(n=>state.Files.ContainsKey(n)&&state.Files.ContainsKey(n.Replace(".wav",".flac"))&&!File.Exists(Path.Combine(current.Folder,n))).ToArray())
            {await TrashAsync(state.Files[stale].Id,true,cancel);state.Files.Remove(stale);Save();}
        }
        finally{gate.Release();}
    }
    public async Task WithdrawAsync(Meeting meeting,CancellationToken cancel=default)
    {
        var state=meeting.Meta.Drive?.Deserialize<State>(JsonFiles.Options);if(state?.FolderID==null)return;
        await TrashAsync(state.FolderID,true,cancel);workspace.Update(meeting.Folder,m=>m.Drive=null);
    }
    public async Task TrashAsync(string id,bool trashed,CancellationToken cancel=default)
    {using var response=await SendAsync(()=>new(HttpMethod.Patch,Files+"/"+Uri.EscapeDataString(id)){Content=JsonContent.Create(new{trashed})},cancel,allowMissing:true);}
    private async Task<bool> LiveAsync(string id,CancellationToken cancel)
    {
        using var response=await SendAsync(()=>new(HttpMethod.Get,Files+"/"+Uri.EscapeDataString(id)+"?fields=trashed"),cancel,true);
        if(response.StatusCode==HttpStatusCode.NotFound)return false;using var doc=JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancel));return !doc.RootElement.GetProperty("trashed").GetBoolean();
    }
    private async Task<string> FolderAsync(string name,string? parent,CancellationToken cancel)
    {
        string Quoted(string s)=>s.Replace("\\","\\\\",StringComparison.Ordinal).Replace("'","\\'",StringComparison.Ordinal);
        var q=$"trashed = false and mimeType = 'application/vnd.google-apps.folder' and name = '{Quoted(name)}'"+(parent!=null?$" and '{Quoted(parent)}' in parents":" and 'root' in parents");
        using var response=await SendAsync(()=>new(HttpMethod.Get,Files+"?fields=files(id)&pageSize=100&q="+Uri.EscapeDataString(q)),cancel);
        using var doc=JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancel));var folders=doc.RootElement.GetProperty("files");
        return folders.GetArrayLength()>0?folders[0].GetProperty("id").GetString()!:await CreateFolderAsync(name,parent,cancel);
    }
    private async Task<string> CreateFolderAsync(string name,string? parent,CancellationToken cancel)
    {
        var body=new Dictionary<string,object>{{"name",name},{"mimeType","application/vnd.google-apps.folder"}};if(parent!=null)body["parents"]=new[]{parent};
        using var response=await SendAsync(()=>new(HttpMethod.Post,Files+"?fields=id"){Content=JsonContent.Create(body)},cancel);using var doc=JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancel));return doc.RootElement.GetProperty("id").GetString()!;
    }
    public static string ContentRange(long offset,int length,long total)=>length==0?$"bytes */{total}":$"bytes {offset}-{offset+length-1}/{total}";
    public static long CommittedBytes(string? range)=>range!=null&&long.TryParse(range.Split('-').LastOrDefault(),out var end)?end+1:0;
    private async Task<string> UploadAsync(string file,string parent,string? existing,CancellationToken cancel)
    {
        var total=new FileInfo(file).Length;
        var url="https://www.googleapis.com/upload/drive/v3/files"+(existing!=null?"/"+Uri.EscapeDataString(existing):"")+"?uploadType=resumable&fields=id";
        var body=new Dictionary<string,object>{{"name",Path.GetFileName(file)}};if(existing==null)body["parents"]=new[]{parent};
        using var initiated=await SendAsync(()=>
        {
            var request=new HttpRequestMessage(existing==null?HttpMethod.Post:HttpMethod.Patch,url){Content=JsonContent.Create(body)};
            request.Headers.Add("X-Upload-Content-Length",total.ToString(System.Globalization.CultureInfo.InvariantCulture));request.Headers.Add("X-Upload-Content-Type",Mime(file));return request;
        },cancel);
        var location=initiated.Headers.Location??throw new IOException("Google returned no resumable upload session");
        if(location.Scheme!="https"||location.Host!="www.googleapis.com")throw new IOException("Unexpected Google upload endpoint");
        await using var source=File.OpenRead(file);var buffer=new byte[8*1024*1024];long offset=0;
        while(offset<total||total==0)
        {
            cancel.ThrowIfCancellationRequested();source.Position=offset;var length=(int)Math.Min(buffer.Length,total-offset);if(length>0)await source.ReadExactlyAsync(buffer.AsMemory(0,length),cancel);
            using var uploaded=await SendAsync(()=>
            {
                var content=new ByteArrayContent(buffer,0,length);content.Headers.ContentType=new(Mime(file));content.Headers.TryAddWithoutValidation("Content-Range",ContentRange(offset,length,total));return new(HttpMethod.Put,location){Content=content};
            },cancel,allowResume:true);
            if((int)uploaded.StatusCode==308)
            {
                var committed=CommittedBytes(uploaded.Headers.TryGetValues("Range",out var range)?range.FirstOrDefault():null);
                if(committed<=offset||committed>offset+length)throw new IOException("Google upload did not advance");offset=committed;continue;
            }
            using var doc=JsonDocument.Parse(await uploaded.Content.ReadAsStringAsync(cancel));return doc.RootElement.GetProperty("id").GetString()!;
        }
        throw new IOException("Google upload ended without a file ID");
    }
    private static string Mime(string path)=>Path.GetExtension(path).ToLowerInvariant() switch{".md"=>"text/markdown",".mp4"=>"video/mp4",".wav"=>"audio/wav",".flac"=>"audio/flac",".jpg" or ".jpeg"=>"image/jpeg",".png"=>"image/png",_=>"application/octet-stream"};
    private async Task<HttpResponseMessage> SendAsync(Func<HttpRequestMessage> create,CancellationToken cancel,bool allowMissing=false,bool allowResume=false)
    {
        var force=false;
        for(var attempt=0;attempt<5;attempt++)
        {
            using var request=create();request.Headers.Authorization=new AuthenticationHeaderValue("Bearer",await auth.AccessAsync(force,cancel));force=false;
            HttpResponseMessage response;
            try{response=await http.SendAsync(request,cancel);}catch(HttpRequestException)when(attempt<4){await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2,attempt)),cancel);continue;}
            if(response.StatusCode==HttpStatusCode.Unauthorized&&attempt<4){response.Dispose();force=true;continue;}
            if(((int)response.StatusCode==429||(int)response.StatusCode>=500)&&attempt<4){response.Dispose();await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2,attempt)),cancel);continue;}
            if(response.IsSuccessStatusCode||allowMissing&&response.StatusCode==HttpStatusCode.NotFound||allowResume&&(int)response.StatusCode==308)return response;
            var status=response.StatusCode;response.Dispose();throw new HttpRequestException("Google Drive request failed: "+(int)status,null,status);
        }
        throw new IOException("Google Drive retry limit reached");
    }
}
