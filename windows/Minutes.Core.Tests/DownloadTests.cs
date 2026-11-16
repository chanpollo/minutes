using System.Net;
using System.Net.Http.Headers;
using Minutes.Core;
using Xunit;

namespace Minutes.Core.Tests;
public sealed class DownloadTests
{
    private sealed class Handler(Func<HttpRequestMessage,HttpResponseMessage> respond):HttpMessageHandler
    {protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancel)=>Task.FromResult(respond(request));}
    [Fact] public async Task ResumesAtExistingPrefix()
    {
        var part=Path.Combine(Path.GetTempPath(),"minutes-download-"+Guid.NewGuid());await File.WriteAllTextAsync(part,"syn");
        using var client=new HttpClient(new Handler(request=>{Assert.Equal(3,request.Headers.Range!.Ranges.Single().From);var response=new HttpResponseMessage(HttpStatusCode.PartialContent){Content=new StringContent("thetic")};response.Content.Headers.ContentRange=new ContentRangeHeaderValue(3,8,9);return response;}));
        try{await ResumableDownload.FetchAsync(client,"https://example.invalid/model",part);Assert.Equal("synthetic",await File.ReadAllTextAsync(part));}finally{File.Delete(part);}
    }
    [Fact] public async Task ServerIgnoringRangeReplacesPrefix()
    {
        var part=Path.Combine(Path.GetTempPath(),"minutes-download-"+Guid.NewGuid());await File.WriteAllTextAsync(part,"bad-prefix");using var client=new HttpClient(new Handler(_=>new(HttpStatusCode.OK){Content=new StringContent("synthetic")}));
        try{await ResumableDownload.FetchAsync(client,"https://example.invalid/model",part);Assert.Equal("synthetic",await File.ReadAllTextAsync(part));}finally{File.Delete(part);}
    }
    [Fact] public async Task WrongResumeRangeDoesNotAppend()
    {
        var part=Path.Combine(Path.GetTempPath(),"minutes-download-"+Guid.NewGuid());await File.WriteAllTextAsync(part,"syn");using var client=new HttpClient(new Handler(_=>{var response=new HttpResponseMessage(HttpStatusCode.PartialContent){Content=new StringContent("thetic")};response.Content.Headers.ContentRange=new ContentRangeHeaderValue(2,7,9);return response;}));
        try{await Assert.ThrowsAsync<IOException>(()=>ResumableDownload.FetchAsync(client,"https://example.invalid/model",part));Assert.Equal("syn",await File.ReadAllTextAsync(part));}finally{File.Delete(part);}
    }
}
