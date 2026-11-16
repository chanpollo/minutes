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
