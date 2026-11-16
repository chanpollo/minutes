using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Minutes.Core;

public interface ITokenStore
{
    string? Read();
    void Save(string value);
    void Delete();
}
public sealed class GoogleOAuth(string clientID,string clientSecret,ITokenStore tokens,HttpClient http)
{
    private readonly SemaphoreSlim refreshGate=new(1);
    private string? access;
    private DateTimeOffset expires;
    public bool Connected=>tokens.Read()!=null;
    public static string Base64Url(byte[] bytes)=>Convert.ToBase64String(bytes).TrimEnd('=').Replace('+','-').Replace('/','_');
    public static string Challenge(string verifier)=>Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
    public async Task ConnectAsync(Action<Uri> openBrowser,CancellationToken cancel=default)
    {
        if(string.IsNullOrWhiteSpace(clientID)||string.IsNullOrWhiteSpace(clientSecret))throw new InvalidOperationException("Add your Google Desktop OAuth client ID and secret before connecting");
        var verifier=Base64Url(RandomNumberGenerator.GetBytes(32));var state=Base64Url(RandomNumberGenerator.GetBytes(32));
        var listener=new TcpListener(IPAddress.Loopback,0);listener.Start();
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(cancel);timeout.CancelAfter(TimeSpan.FromMinutes(5));
        var port=((IPEndPoint)listener.LocalEndpoint).Port;var redirect=$"http://127.0.0.1:{port}";
        var fields=new Dictionary<string,string>{{"client_id",clientID},{"redirect_uri",redirect},{"response_type","code"},{"scope","https://www.googleapis.com/auth/drive.file"},{"code_challenge",Challenge(verifier)},{"code_challenge_method","S256"},{"state",state},{"access_type","offline"},{"prompt","consent"}};
        string? code=null;
        try
        {
            openBrowser(new Uri("https://accounts.google.com/o/oauth2/v2/auth?"+string.Join("&",fields.Select(p=>Uri.EscapeDataString(p.Key)+"="+Uri.EscapeDataString(p.Value)))));
            while(code==null)
            {
                using var connection=await listener.AcceptTcpClientAsync(timeout.Token);using var stream=connection.GetStream();
                using var requestTimeout=CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);requestTimeout.CancelAfter(TimeSpan.FromSeconds(5));
                var bytes=new List<byte>();var buffer=new byte[1024];
                while(bytes.Count<16384)
                {
                    var n=await stream.ReadAsync(buffer,requestTimeout.Token);if(n==0)break;bytes.AddRange(buffer.Take(n));if(Encoding.ASCII.GetString(bytes.ToArray()).Contains("\r\n\r\n",StringComparison.Ordinal))break;
                }
                var head=Encoding.ASCII.GetString(bytes.ToArray()).Split("\r\n")[0].Split(' ');
                var query=head.Length==3&&head[0]=="GET"&&Uri.TryCreate(redirect+head[1],UriKind.Absolute,out var uri)?ParseQuery(uri.Query):new Dictionary<string,string>();
                var valid=query.GetValueOrDefault("state")==state;
                var body=valid?"Minutes received the sign-in. You can close this tab.":"This sign-in does not belong to this window.";
                var reply=Encoding.UTF8.GetBytes($"HTTP/1.1 {(valid?"200 OK":"400 Bad Request")}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {Encoding.UTF8.GetByteCount(body)}\r\nConnection: close\r\n\r\n{body}");await stream.WriteAsync(reply,requestTimeout.Token);
                if(!valid)continue;
                if(query.ContainsKey("error"))throw new InvalidOperationException("Google sign-in was declined");
                code=query.GetValueOrDefault("code");if(string.IsNullOrEmpty(code))throw new InvalidDataException("Google returned no authorization code");
            }
        }
        finally{listener.Stop();}
        var token=await TokenAsync(new(){{"code",code},{"client_id",clientID},{"client_secret",clientSecret},{"redirect_uri",redirect},{"grant_type","authorization_code"},{"code_verifier",verifier}},cancel);
        if(!token.TryGetProperty("refresh_token",out var refresh))throw new InvalidDataException("Google returned no refresh token");tokens.Save(refresh.GetString()!);Cache(token);
    }
    public static Dictionary<string,string> ParseQuery(string query)=>query.TrimStart('?').Split('&',StringSplitOptions.RemoveEmptyEntries).Select(p=>p.Split('=',2)).GroupBy(p=>Uri.UnescapeDataString(p[0])).ToDictionary(g=>g.Key,g=>Uri.UnescapeDataString(g.Last().ElementAtOrDefault(1)?.Replace('+',' ')??""));
    public async Task<string> AccessAsync(bool force=false,CancellationToken cancel=default)
    {
        await refreshGate.WaitAsync(cancel);
        try
        {
            if(!force&&access!=null&&expires>DateTimeOffset.UtcNow)return access;
            var refresh=tokens.Read()??throw new InvalidOperationException("Google Drive is not connected");
            var token=await TokenAsync(new(){{"refresh_token",refresh},{"client_id",clientID},{"client_secret",clientSecret},{"grant_type","refresh_token"}},cancel);Cache(token);return access!;
        }
        finally{refreshGate.Release();}
    }
    public async Task DisconnectAsync(CancellationToken cancel=default)
    {
        var refresh=tokens.Read();tokens.Delete();access=null;
        if(refresh!=null){using var response=await http.PostAsync("https://oauth2.googleapis.com/revoke",new FormUrlEncodedContent(new Dictionary<string,string>{{"token",refresh}}),cancel);}
    }
    private void Cache(JsonElement token){access=token.GetProperty("access_token").GetString();expires=DateTimeOffset.UtcNow.AddSeconds(token.TryGetProperty("expires_in",out var seconds)?seconds.GetDouble()-60:3540);}
    private async Task<JsonElement> TokenAsync(Dictionary<string,string> fields,CancellationToken cancel)
    {
        using var response=await http.PostAsync("https://oauth2.googleapis.com/token",new FormUrlEncodedContent(fields),cancel);using var json=JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancel));
        if(!response.IsSuccessStatusCode)
        {
            if(json.RootElement.TryGetProperty("error",out var error)&&error.GetString()=="invalid_grant"){tokens.Delete();access=null;}
            throw new HttpRequestException("Google authentication failed. Sign in again.",null,response.StatusCode);
        }
        return json.RootElement.Clone();
    }
}
