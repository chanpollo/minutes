using System.Net;
using System.Text;
using Minutes.Core;
using Xunit;

namespace Minutes.Core.Tests;
public sealed class GoogleTests
{
    private sealed class Tokens:ITokenStore{public string? Value="synthetic-refresh";public string? Read()=>Value;public void Save(string value)=>Value=value;public void Delete()=>Value=null;}
    private sealed class Handler(Func<HttpRequestMessage,int,HttpResponseMessage> handle):HttpMessageHandler
    {
        private int count;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancel)=>Task.FromResult(handle(request,++count));
    }
    [Fact] public void PkceMatchesRfc7636Vector()=>Assert.Equal("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",GoogleOAuth.Challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
    [Fact] public async Task RefreshIsCachedAndForceRefreshes()
    {
        var calls=0;using var http=new HttpClient(new Handler((request,n)=>{calls++;Assert.Equal("https://oauth2.googleapis.com/token",request.RequestUri!.AbsoluteUri);return new(HttpStatusCode.OK){Content=new StringContent("{\"access_token\":\"synthetic-access\",\"expires_in\":3600}")};}));
        var auth=new GoogleOAuth("synthetic-client","synthetic-secret",new Tokens(),http);Assert.Equal("synthetic-access",await auth.AccessAsync());Assert.Equal("synthetic-access",await auth.AccessAsync());Assert.Equal(1,calls);await auth.AccessAsync(true);Assert.Equal(2,calls);
    }
    [Fact] public async Task InvalidGrantClearsRefreshTokenWithoutLeakingBody()
    {
        var tokens=new Tokens();using var http=new HttpClient(new Handler((_,_)=>new(HttpStatusCode.BadRequest){Content=new StringContent("{\"error\":\"invalid_grant\",\"private_details\":\"do-not-show\"}")}));
        var error=await Assert.ThrowsAsync<HttpRequestException>(()=>new GoogleOAuth("synthetic","synthetic",tokens,http).AccessAsync());Assert.Null(tokens.Value);Assert.DoesNotContain("do-not-show",error.Message);
    }
    [Theory][InlineData(0,8388608,10000000,"bytes 0-8388607/10000000")][InlineData(8388608,1611392,10000000,"bytes 8388608-9999999/10000000")][InlineData(0,0,0,"bytes */0")]
    public void UploadRanges(long offset,int length,long total,string expected)=>Assert.Equal(expected,GoogleDriveSync.ContentRange(offset,length,total));
    [Theory][InlineData(null,0)][InlineData("bytes=0-8388607",8388608)][InlineData("invalid",0)]
    public void ServerCommittedBytes(string? range,long expected)=>Assert.Equal(expected,GoogleDriveSync.CommittedBytes(range));
    [Fact] public void QueryDecodedAndDuplicateLastWins()
    {var query=GoogleOAuth.ParseQuery("?state=wrong&state=right&code=synthetic%2Bcode+value");Assert.Equal("right",query["state"]);Assert.Equal("synthetic+code value",query["code"]);}
}

public sealed class DriveBoundaryTests
{
    private sealed class Tokens:ITokenStore{public string? Read()=>"synthetic-refresh";public void Save(string value){}public void Delete(){}}
    private sealed class Handler(Func<HttpRequestMessage,HttpResponseMessage> respond):HttpMessageHandler
    {protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancel)=>Task.FromResult(respond(request));}
    private static HttpResponseMessage Json(string body)=>new(HttpStatusCode.OK){Content=new StringContent(body)};
    [Fact] public async Task LostChunkResponseProbesAndResumesAtServerOffset()
    {
        var root=Path.Combine(Path.GetTempPath(),"minutes-drive-"+Guid.NewGuid());var workspace=new Workspace(root);var meeting=workspace.MakeNote();File.WriteAllText(Path.Combine(meeting.Folder,"notes.md"),"synthetic");
        workspace.Update(meeting.Folder,m=>m.Drive=System.Text.Json.JsonSerializer.SerializeToElement(new GoogleDriveSync.State{FolderID="folder",FolderName=Path.GetFileName(meeting.Folder)},JsonFiles.Options));
        var ranges=new List<string>();
        using var http=new HttpClient(new Handler(request=>
        {
            var url=request.RequestUri!.AbsoluteUri;
            if(url.Contains("/token",StringComparison.Ordinal))return Json("{\"access_token\":\"synthetic-access\",\"expires_in\":3600}");
            if(url.Contains("?fields=files",StringComparison.Ordinal))return Json("{\"files\":[{\"id\":\"root\"}]}");
            if(url.Contains("fields=trashed",StringComparison.Ordinal))return Json("{\"trashed\":false}");
            if(url.Contains("uploadType=resumable",StringComparison.Ordinal)){var result=Json("{}");result.Headers.Location=new Uri("https://www.googleapis.com/upload/session/synthetic");return result;}
            if(url.EndsWith("/session/synthetic",StringComparison.Ordinal))
            {
                var range=request.Content!.Headers.GetValues("Content-Range").Single();ranges.Add(range);
                if(range=="bytes 0-8/9")return new(HttpStatusCode.BadRequest);
                if(range=="bytes */9"){var response=new HttpResponseMessage((HttpStatusCode)308);response.Headers.TryAddWithoutValidation("Range","bytes=0-3");return response;}
                Assert.Equal("bytes 4-8/9",range);Assert.Equal("hetic",request.Content.ReadAsStringAsync().GetAwaiter().GetResult());return Json("{\"id\":\"uploaded\"}");
            }
            throw new InvalidOperationException("Unexpected synthetic request: "+url);
        }));
        try{await new GoogleDriveSync(workspace,new GoogleOAuth("synthetic","synthetic",new Tokens(),http),http).CopyAsync(meeting,new(true,false));Assert.Equal(new[]{"bytes 0-8/9","bytes */9","bytes 4-8/9"},ranges);}
        finally{Directory.Delete(root,true);}
    }
    [Fact] public async Task RenameWithinSameGroupDoesNotRemoveItsParent()
    {
        var root=Path.Combine(Path.GetTempPath(),"minutes-drive-"+Guid.NewGuid());var workspace=new Workspace(root);var meeting=workspace.MakeNote();workspace.Update(meeting.Folder,m=>m.Drive=System.Text.Json.JsonSerializer.SerializeToElement(new GoogleDriveSync.State{FolderID="folder",FolderName="Old"},JsonFiles.Options));var patched=false;
        using var http=new HttpClient(new Handler(request=>
        {
            var url=request.RequestUri!.AbsoluteUri;if(url.Contains("/token",StringComparison.Ordinal))return Json("{\"access_token\":\"synthetic\",\"expires_in\":3600}");if(url.Contains("?fields=files",StringComparison.Ordinal))return Json("{\"files\":[{\"id\":\"root\"}]}");if(url.Contains("fields=trashed",StringComparison.Ordinal))return Json("{\"trashed\":false}");if(request.Method==HttpMethod.Patch){Assert.DoesNotContain("Parents",url);patched=true;return Json("{}");}throw new InvalidOperationException("Unexpected request");
        }));
        try{await new GoogleDriveSync(workspace,new GoogleOAuth("synthetic","synthetic",new Tokens(),http),http).CopyAsync(meeting,new(false,false));Assert.True(patched);}
        finally{Directory.Delete(root,true);}
    }
}
