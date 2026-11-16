using System.Text.Json;

namespace Minutes.Core;
public static class ModelCatalog
{
    public static IReadOnlyList<string> Models(string provider,string? home=null)
    {
        home??=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if(provider=="claude")return ["sonnet","opus","haiku"];
        if(provider=="codex")
        {
            var codex=Environment.GetEnvironmentVariable("CODEX_HOME")??Path.Combine(home,".codex");
            try
            {
                using var doc=JsonDocument.Parse(File.ReadAllText(Path.Combine(codex,"models_cache.json")));
                var models=doc.RootElement.GetProperty("models").EnumerateArray().Where(m=>m.TryGetProperty("visibility",out var v)&&v.GetString()=="list").OrderBy(m=>m.TryGetProperty("priority",out var p)?p.GetInt32():int.MaxValue).Select(m=>m.GetProperty("slug").GetString()!).Take(5).ToArray();if(models.Length>0)return models;
            }
            catch(Exception e)when(e is IOException or JsonException or KeyNotFoundException){}
            return [""];
        }
        if(provider=="ollama")
        {
            var root=Path.Combine(Environment.GetEnvironmentVariable("OLLAMA_MODELS")??Path.Combine(home,".ollama","models"),"manifests");if(!Directory.Exists(root))return [];
            return Directory.EnumerateFiles(root,"*",SearchOption.AllDirectories).Select(p=>Path.GetRelativePath(root,p).Split(Path.DirectorySeparatorChar)).Where(p=>p.Length==4&&!p[3].StartsWith('.')).Select(p=>(p[0]=="registry.ollama.ai"?(p[1]=="library"?p[2]:p[1]+"/"+p[2]):p[0]+"/"+p[1]+"/"+p[2])+":"+p[3]).Order(StringComparer.Ordinal).ToArray();
        }
        return [""];
    }
}
