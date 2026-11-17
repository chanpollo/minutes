using Minutes.Core;
using System.Text.Json;

namespace Minutes.App;
internal static class BuildInfo
{
    public static string Report()
    {
        var version = "1.1.0"; var build = "local"; var commit = "local"; var built = "local build";
        var file = Path.Combine(AppContext.BaseDirectory, "build.json");
        if (File.Exists(file))
        {
            using var json = JsonDocument.Parse(File.ReadAllText(file)); var data = json.RootElement;
            version = data.GetProperty("version").GetString() ?? version; build = data.GetProperty("build").GetString() ?? build; commit = data.GetProperty("commit").GetString() ?? commit; built = data.GetProperty("builtUtc").GetString() ?? built;
        }
        var opened = Path.Combine(AppSettings.Support, "first-opened.txt");
        if (!File.Exists(opened)) { Directory.CreateDirectory(AppSettings.Support); File.WriteAllText(opened, DateTimeOffset.UtcNow.ToString("O")); }
        return $"Minutes {version} · Windows build {build}\nCommit: {commit}\nBuilt: {built}\nFirst opened: {File.ReadAllText(opened)}";
    }
}
